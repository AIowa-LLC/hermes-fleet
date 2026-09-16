import XCTest
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetSecurity
import FleetUI

/// "Continue as Interactive Group" (diagnostic 2026-09-15, fix B): a legacy
/// Desktop-projection room is continued into an authoritative hosted room
/// by reusing the projection's durable room id via `groups.create` —
/// equality-by-construction becomes the Desktop ↔ hosted identity link.
///
/// These tests pin the environment-level flow: member verification against
/// the live roster, idempotent create with the REUSED id, the returned
/// hosted room's identity, and fail-closed paths.
@MainActor
final class LegacyRoomContinueFlowTests: XCTestCase {

    // MARK: Test doubles (self-contained; sibling suites keep theirs private)

    private struct TestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
        func connect() async throws {}
        func disconnect() async {}
    }

    private struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        let profiles: [ProfileDescriptor]
        var status: GatewayStatus = .online
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { profiles }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct TestSessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private final class TestHealthAccumulator: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    /// Room-command seam recording the create call.
    private actor RecordingRoomCommands: RoomChatCommanding {
        private(set) var createdRoomIDs: [String] = []
        private(set) var createdNames: [String] = []
        private(set) var createdMembers: [[[String: String]]] = []

        func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
            RoomLogPageSlice(
                events: [], cursor: 0, latestSeq: 0, hasMore: false,
                authorityGatewayID: "workstation", authorityEpoch: 1)
        }

        func send(roomID: String, text: String, threadID: String?) async throws -> Int { 1 }

        func rename(roomID: String, name: String) async throws {}

        func disband(roomID: String) async throws {}

        func stop(roomID: String) async throws -> Int { 0 }

        func retry(roomID: String, taskID: String) async throws {}

        func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws {}

        func createRoom(roomID: String, name: String, members: [[String: String]]) async throws -> String {
            createdRoomIDs.append(roomID)
            createdNames.append(name)
            createdMembers.append(members)
            return roomID
        }
    }

    /// Create seam that always conflicts (4110 shape).
    private struct ConflictRoomCommands: RoomChatCommanding {
        func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
            RoomLogPageSlice(
                events: [], cursor: 0, latestSeq: 0, hasMore: false,
                authorityGatewayID: "workstation", authorityEpoch: 1)
        }
        func send(roomID: String, text: String, threadID: String?) async throws -> Int { 1 }
        func rename(roomID: String, name: String) async throws {}
        func disband(roomID: String) async throws {}
        func stop(roomID: String) async throws -> Int { 0 }
        func retry(roomID: String, taskID: String) async throws {}
        func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws {}
        func createRoom(roomID: String, name: String, members: [[String: String]]) async throws -> String {
            throw RoomCommandFailure.rpcFailed("room_id already exists with different state", 4110)
        }
    }

    private struct ScriptedRoomSource: FleetRoomSourceProviding {
        var roomsToServe: [FleetRoom]
        func rooms() async -> [FleetRoom] { roomsToServe }
        func createRoomCapability() async -> GroupsCreateCapability { .unknown }
    }

    // MARK: Fixtures

    private func makeEnvironment(
        rooms: [FleetRoom],
        commands: some RoomChatCommanding,
        profiles: [String]
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id)
            }
        )
        let descriptors = profiles.map {
            ProfileDescriptor(name: $0, path: "/synthetic/profiles/\($0)")
        }
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: descriptors)
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id)
            },
            roomSourceFactory: { _ in ScriptedRoomSource(roomsToServe: rooms) },
            roomCommandFactory: { _ in commands },
            health: TestHealthAccumulator(),
            seedRegistrations: [
                GatewayRegistration(
                    id: GatewayID(rawValue: "workstation"),
                    displayName: "Workstation",
                    endpoint: URL(string: "http://127.0.0.1:9119")!)
            ]
        )
        await environment.load()
        return environment
    }

    /// The live room shape from the 2026-09-15 diagnostic: id-keyed v3
    /// projection, local + cross-machine members, `iOS App Brainstorming Crew`.
    private func diagnosticLegacyRoom() -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(
                provenance: .desktopLegacy,
                gatewayID: GatewayID(rawValue: "workstation"),
                key: "id:rmtxtyapg-nsd4n"),
            name: "iOS App Brainstorming Crew",
            members: [
                FleetRoomMember(name: "default", handle: "default-this-device", connectionID: "local", connectionLabel: "This device", sourceScoped: true),
                FleetRoomMember(name: "apple", handle: "apple", connectionID: "local", connectionLabel: "This device", sourceScoped: true),
                FleetRoomMember(name: "researcher", handle: "researcher", connectionID: "peer-host-a", connectionLabel: "Peer Host A", sourceScoped: true),
            ],
            recentLog: [],
            revision: 824)
    }

    // MARK: Tests

    func testContinueReusesDurableIDAndVerifiesMembers() async throws {
        let commands = RecordingRoomCommands()
        let environment = await makeEnvironment(
            rooms: [diagnosticLegacyRoom()],
            commands: commands,
            profiles: ["default", "apple", "researcher"])
        await environment.refreshRoster()

        let room = try await environment.continueLegacyRoomAsInteractive(
            diagnosticLegacyRoom())

        // Identity: the hosted room reuses the projection's durable id.
        XCTAssertEqual(room.id.provenance, .hosted)
        XCTAssertEqual(room.id.key, "rmtxtyapg-nsd4n")

        // The wire create carried the SAME id (equality-by-construction).
        let wireRoomID = await commands.createdRoomIDs.first
        XCTAssertEqual(wireRoomID, "rmtxtyapg-nsd4n")
        let wireName = await commands.createdNames.first
        XCTAssertEqual(wireName, "iOS App Brainstorming Crew")

        // Only roster-verified local members are on the wire; the
        // cross-machine researcher is not (it would fail roster
        // validation server-side).
        let wireMembers = await commands.createdMembers.first ?? []
        XCTAssertEqual(wireMembers.map { $0["profile"] }, ["default", "apple"])

        // The created hosted room is resolvable in the environment.
        let hostedRooms = environment.rooms(for: room.id.gatewayID)
            .filter { $0.id.provenance == .hosted && $0.id.key == "rmtxtyapg-nsd4n" }
        XCTAssertEqual(hostedRooms.count, 1)
    }

    func testContinueRejectsNameKeyedRoomFailClosed() async throws {
        let commands = RecordingRoomCommands()
        let environment = await makeEnvironment(
            rooms: [], commands: commands, profiles: ["default", "apple"])

        let nameKeyed = FleetRoom(
            id: FleetRoomID(
                provenance: .desktopLegacy,
                gatewayID: GatewayID(rawValue: "workstation"),
                key: "name:Research Crew"),
            name: "Research Crew",
            members: [
                FleetRoomMember(name: "default", connectionID: "local"),
                FleetRoomMember(name: "apple", connectionID: "local"),
            ])

        do {
            _ = try await environment.continueLegacyRoomAsInteractive(nameKeyed)
            XCTFail("expected a thrown error")
        } catch let error as RoomCommandFailure {
            guard case .rpcFailed(let message, _) = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("durable"), "message should explain durable-id absence: \(message)")
        }
        let createCount = await commands.createdRoomIDs.count
        XCTAssertEqual(createCount, 0, "no create may be issued for a name-keyed room")
    }

    func testContinueRejectsWhenMembersDoNotVerify() async throws {
        let commands = RecordingRoomCommands()
        // `apple` missing from the roster — the projected local member
        // cannot verify, so continuation fails closed.
        let environment = await makeEnvironment(
            rooms: [], commands: commands, profiles: ["default"])

        do {
            _ = try await environment.continueLegacyRoomAsInteractive(diagnosticLegacyRoom())
            XCTFail("expected a thrown error")
        } catch let error as RoomCommandFailure {
            guard case .rpcFailed(let message, _) = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("apple"),
                "message should name the unverified member: \(message)")
        }
        let createCount = await commands.createdRoomIDs.count
        XCTAssertEqual(createCount, 0, "no create may be issued when members fail verification")
    }

    func testContinueRequiresRosterQuorumOfTwo() async throws {
        let commands = RecordingRoomCommands()
        let environment = await makeEnvironment(
            rooms: [], commands: commands, profiles: [])

        do {
            _ = try await environment.continueLegacyRoomAsInteractive(diagnosticLegacyRoom())
            XCTFail("expected a thrown error")
        } catch let error as RoomCommandFailure {
            guard case .rpcFailed = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
        }
        let createCount = await commands.createdRoomIDs.count
        XCTAssertEqual(createCount, 0, "no create without the 2-member hosted minimum")
    }

    func testContinueSurfacesCreateConflictAsTypedError() async throws {
        // A pre-existing hosted row with the same id but different state
        // (4110 RoomConflictError) must surface as a typed failure — never
        // a silent retry loop or an invented room.
        let environment = await makeEnvironment(
            rooms: [], commands: ConflictRoomCommands(),
            profiles: ["default", "apple", "researcher"])
        await environment.refreshRoster()

        do {
            _ = try await environment.continueLegacyRoomAsInteractive(diagnosticLegacyRoom())
            XCTFail("expected a thrown error")
        } catch let error as RoomCommandFailure {
            guard case .rpcFailed(let message, let code) = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
            XCTAssertEqual(code, 4110)
            XCTAssertTrue(message.contains("different state"))
        }
    }
}
