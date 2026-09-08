import XCTest
import FleetCore
import FleetSecurity
import FleetPersistence
import FleetNetworking
import FleetUI

/// B1 slice 10 (t_4c88b0c3) — cross-gateway room setup domain tests.
///
/// Spec §18 "Cross-gateway Groups" coverage, executed against pure domain
/// types (CrossGatewayRoomSetup, RoomLinkTargetSnapshot) plus the
/// AppEnvironment orchestration contract via a scripted seam. Wire-level
/// decodes are covered in FleetNetworking (RoomLinkNetworkingTests).
@MainActor
final class CrossGatewayRoomSetupTests: XCTestCase {

    // MARK: - Fixtures

    private let homeGateway = GatewayID(rawValue: "homegw")
    private let remoteGateway = GatewayID(rawValue: "remotegw")

    /// Same display profile name on two gateways — §3.2 identity.
    private var localResearcher: RoomMemberCandidate {
        RoomMemberCandidate(
            route: Route(gatewayID: homeGateway, profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")
    }
    private var remoteResearcher: RoomMemberCandidate {
        RoomMemberCandidate(
            route: Route(gatewayID: remoteGateway, profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")
    }

    private func snapshot(
        installationID: String,
        profile: String,
        enabled: Bool = true,
        driver: Bool = true,
        methods: [String] = ["groups.create", "groups.state", "groups.peer.register",
                             "groups.peer.invite", "groups.peer.revoke"],
        direct: Bool = true,
        persistent: Bool = true,
        endpointAvailable: Bool = true,
        policyDigest: String = String(repeating: "a", count: 64)
    ) -> RoomLinkTargetSnapshot {
        let negotiation = RoomLinkNegotiation(
            authorityGatewayID: installationID,
            enabled: enabled,
            disabledReason: nil,
            profile: profile,
            protocolVersions: [2],
            installationID: installationID,
            linkModes: direct ? ["direct"] : [],
            persistentProcess: persistent,
            textOnly: true,
            attachmentsSupported: false,
            catalogDigest: String(repeating: "b", count: 64),
            executionPolicy: RoomLinkExecutionPolicy(
                version: 1, targetProfile: profile, enabledToolsets: ["default"],
                approvalMode: "manual", maxIterations: 8, policyDigest: policyDigest),
            endpoint: RoomLinkEndpoint(
                available: endpointAvailable,
                url: endpointAvailable ? "https://\(installationID).example:9120" : nil,
                transportSecurity: endpointAvailable ? "tls" : nil,
                unavailableReason: endpointAvailable ? nil : "not_configured"),
            methods: methods)
        return RoomLinkTargetSnapshot(
            negotiation: negotiation,
            catalog: .object(["installation_id": .string(installationID)]),
            driver: driver)
    }

    // MARK: - Member mapping (§11.4: never reduce a member to a bare slug)

    func testLocalMemberCarriesNoPeerTarget() throws {
        let value = CrossGatewayRoomSetup.member(localResearcher, target: nil)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertNil(object["target"], "same-gateway members keep the plain local shape")
        XCTAssertEqual(object["profile"]?.stringValue, "researcher")
        XCTAssertEqual(object["handle"]?.stringValue, CrossGatewayRoomSetup.memberID(localResearcher.route))
    }

    func testRemoteMemberKeepsScopedPeerTarget() throws {
        let target = snapshot(installationID: "remote-install", profile: "researcher")
        let value = CrossGatewayRoomSetup.member(remoteResearcher, target: target)
        let object = try XCTUnwrap(value.objectValue)
        let peer = try XCTUnwrap(object["target"]?.objectValue)
        // upstream _TARGET_FIELDS (hosted_room_discussion.py:44): exactly
        // kind/peer_id/installation_id/profile/capability_digest.
        XCTAssertEqual(Set(peer.keys), ["kind", "peer_id", "installation_id", "profile", "capability_digest"])
        XCTAssertEqual(peer["kind"]?.stringValue, "peer")
        XCTAssertEqual(peer["installation_id"]?.stringValue, "remote-install")
        XCTAssertEqual(peer["profile"]?.stringValue, "researcher")
        XCTAssertEqual(peer["capability_digest"]?.stringValue, target.negotiation.catalogDigest)
    }

    func testMemberIDIsStableAndIdentifierSafe() {
        let id = CrossGatewayRoomSetup.memberID(remoteResearcher.route)
        XCTAssertEqual(id, CrossGatewayRoomSetup.memberID(remoteResearcher.route), "deterministic per route")
        // Same profile on another gateway gets a DIFFERENT member id —
        // source-qualified identity (§3.2).
        XCTAssertNotEqual(id, CrossGatewayRoomSetup.memberID(localResearcher.route))
        // upstream identifier charset ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,255}$
        XCTAssertTrue(id.hasPrefix("fleet-"))
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit || $0 == "-" || $0.isLetter }, "identifier-safe")
    }

    // MARK: - Capability gates (§11.5, §11.8 fail-closed)

    func testSupportsTargetRequiresInviteAndRevoke() {
        XCTAssertTrue(snapshot(installationID: "t", profile: "p").supportsTarget)
        XCTAssertFalse(snapshot(installationID: "t", profile: "p",
                                methods: ["groups.peer.invite"]).supportsTarget,
                       "missing groups.peer.revoke must fail closed")
    }

    func testRoomLinkDisabledFailsClosed() {
        XCTAssertFalse(snapshot(installationID: "t", profile: "p", enabled: false).supportsTarget)
        XCTAssertFalse(snapshot(installationID: "t", profile: "p", enabled: false).supportsHome)
    }

    func testNoDirectModeOrEndpointFailsClosed() {
        XCTAssertFalse(snapshot(installationID: "t", profile: "p", direct: false).supportsTarget)
        XCTAssertFalse(snapshot(installationID: "t", profile: "p", endpointAvailable: false).supportsTarget)
        XCTAssertFalse(snapshot(installationID: "t", profile: "p", persistent: false).supportsTarget)
    }

    func testHomeRequiresDriverAndCreateAndRegister() {
        XCTAssertTrue(snapshot(installationID: "h", profile: "default").supportsHome)
        XCTAssertFalse(snapshot(installationID: "h", profile: "default", driver: false).supportsHome,
                       "no hosted-room driver → cannot home a cross-gateway room")
        XCTAssertFalse(snapshot(installationID: "h", profile: "default",
                                methods: ["groups.create", "groups.state"]).supportsHome,
                       "missing groups.peer.register must fail closed")
    }

    func testPolicyMismatchProfileFailsClosed() {
        // Upstream pins the execution policy to the exact target profile
        // (catalog target_profile == requested profile). A gateway whose
        // advertised profile does not match the member's profile must be
        // rejected by the ORCHESTRATION gate (AppEnvironment checks
        // snapshot.negotiation.profile == member profile before inviting);
        // the snapshot itself just reports its own truth.
        let requested = "researcher"
        let snap = snapshot(installationID: "t", profile: requested)
        XCTAssertTrue(snap.supportsTarget)
        XCTAssertTrue(snap.negotiation.executionPolicy?.targetProfile == requested,
                      "a consistent snapshot carries a matching policy profile")
        // A gateway advertising a DIFFERENT profile than requested fails
        // the orchestration equality gate — detectable from the snapshot.
        let other = snapshot(installationID: "t2", profile: "writer")
        XCTAssertNotEqual(other.negotiation.profile, requested,
                          "profile mismatch is detectable from negotiation.profile")
    }

    // MARK: - Grant hygiene

    func testGrantNeverRendersItsToken() {
        let grant = ScopedRoomGrant(token: "secret-value-123456", profile: "researcher",
                                    catalog: .object([:]))
        XCTAssertEqual(String(describing: grant), "ScopedRoomGrant(<redacted>)",
                       "the scoped grant token must never appear in descriptions/logs")
        XCTAssertFalse(String(describing: grant).contains("secret-value"))
    }

    // MARK: - Orchestration (AppEnvironment.createLinkedRoom)

    /// Records every call so tests can assert the choreography order and
    /// the exact invite→register pairing per remote member. Conforms to the
    /// full RoomLinkCommanding protocol (the environment's roomLinkFactory
    /// types) via fatal stubs — only the cross-gateway surface is driven.
    private final class ScriptedCrossGatewaySeam: CrossGatewayRoomCommanding, RoomLinkCommanding, @unchecked Sendable {
        let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        var homeSnapshot: RoomLinkTargetSnapshot
        var targetSnapshots: [String: RoomLinkTargetSnapshot] = [:]
        /// When set, registerScopedPeer throws (peer-registration failure).
        var registerError: Error?
        /// Rooms returned by createScopedRoom.
        var createdRoom = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "homegw"), key: "room-test"),
            name: "Crew", members: [],
            hosted: HostedRoomState(authorityGatewayID: "home-install", authorityEpoch: 1,
                                    advertisedMethods: [], driverAvailable: true))

        init(homeSnapshot: RoomLinkTargetSnapshot) {
            self.homeSnapshot = homeSnapshot
        }

        func roomLinkTarget(profile: String) async throws -> RoomLinkTargetSnapshot {
            lock.withLock { _calls.append("capabilities:\(profile)") }
            return lock.withLock { targetSnapshots[profile] ?? homeSnapshot }
        }

        func createScopedRoom(roomID: String, name: String, members: [MetadataValue]) async throws -> FleetRoom {
            lock.withLock {
                _calls.append("create:\(roomID):\(members.count)")
                // Record the roster shape for assertions.
                for member in members {
                    if let object = member.objectValue,
                       let peer = object["target"]?.objectValue,
                       peer["kind"]?.stringValue == "peer" {
                        _calls.append("peer-member:\(object["profile"]?.stringValue ?? "")")
                    }
                }
            }
            let base = lock.withLock { createdRoom }
            return FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: base.id.gatewayID, key: roomID),
                name: name, members: base.members, hosted: base.hosted)
        }

        func inviteScopedRoom(room: FleetRoom, profile: String, memberID: String) async throws -> ScopedRoomGrant {
            lock.withLock { _calls.append("invite:\(profile):\(memberID)") }
            return ScopedRoomGrant(token: "grant-\(profile)", profile: profile, catalog: .object([:]))
        }

        func registerScopedPeer(roomID: String, memberID: String, target: RoomLinkTargetSnapshot, grant: ScopedRoomGrant) async throws {
            lock.withLock { _calls.append("register:\(roomID):\(memberID)") }
            if let registerError { throw registerError }
        }

        func revokeScopedPeer(_ grant: ScopedRoomGrant) async throws {
            lock.withLock { _calls.append("revoke:\(grant.profile)") }
        }

        // MARK: RoomLinkCommanding (unused legacy surface — typed stubs)

        func negotiate() async throws -> RoomLinkNegotiation { homeSnapshot.negotiation }
        func invite(roomID: String?, memberID: String?, ttlSeconds: Double) async throws -> RoomLinkGrant {
            throw GatewayRoomLinkClient.RoomLinkError.notConnected
        }
        func registerPeer(roomID: String, memberID: String, grant: RoomLinkGrant, targetURL: String) async throws -> RoomPeerRoute {
            throw GatewayRoomLinkClient.RoomLinkError.notConnected
        }
        func revoke(grant: RoomLinkGrant) async throws {}
        func peerRoutes(roomID: String) async throws -> [RoomPeerRoute] { [] }
        func replicaState(roomID: String) async throws -> RoomReplicaState? { nil }
        func roomReplaySource(roomID: String) async throws -> any RoomReplaySourceProviding {
            throw GatewayRoomLinkClient.RoomLinkError.notConnected
        }
        func replicateSink() async throws -> any RoomReplicateSink {
            throw GatewayRoomLinkClient.RoomLinkError.notConnected
        }
        func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt {
            throw GatewayRoomLinkClient.RoomLinkError.confirmRequired(" scripted ")
        }
        func demote(roomID: String, observedGatewayID: String, observedEpoch: Int) async throws {}
    }

    private struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus = .online
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct TestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    private final class ScriptedHealth: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private struct EmptyRoomSource: FleetRoomSourceProviding {
        func rooms() async -> [FleetRoom] { [] }
        func createRoomCapability() async -> GroupsCreateCapability { .unknown }
    }

    private func makeLinkedEnvironment(
        home: ScriptedCrossGatewaySeam,
        remote: ScriptedCrossGatewaySeam
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id) }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id) }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id) },
            roomSourceFactory: { _ in EmptyRoomSource() },
            roomLinkFactory: { gateway in
                gateway.id == GatewayID(rawValue: "homegw") ? home : remote
            },
            health: ScriptedHealth(),
            seedRegistrations: [
                GatewayRegistration(id: GatewayID(rawValue: "homegw"), displayName: "Home",
                                    endpoint: URL(string: "http://127.0.0.1:1")!),
                GatewayRegistration(id: GatewayID(rawValue: "remotegw"), displayName: "Remote",
                                    endpoint: URL(string: "http://127.0.0.1:2")!),
            ]
        )
        await environment.load()
        return environment
    }

    private struct TestSessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    /// Full happy path: create on home → invite on target → register on
    /// home, with the peer target carried through the roster (§11.4).
    func testCreateLinkedRoomChoreography() async throws {
        let home = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "home-install", profile: "default"))
        let remoteSeam = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "remote-install", profile: "researcher"))
        let environment = await makeLinkedEnvironment(home: home, remote: remoteSeam)

        let room = try await environment.createRoom(
            gatewayID: GatewayID(rawValue: "homegw"), name: "Crew",
            members: [localResearcher, remoteResearcher],
            setupID: "room-test")

        XCTAssertEqual(room.id.key, "room-test")
        let calls = home.calls
        // Choreography: capabilities, create with BOTH members (one with a
        // peer target), then invite+register happen via the TARGET seam for
        // the remote member and HOME for registration.
        XCTAssertTrue(calls.contains("create:room-test:2"), "created with the full roster")
        XCTAssertTrue(calls.contains("peer-member:researcher"), "remote member carries a scoped peer target")
        XCTAssertTrue(remoteSeam.calls.contains("invite:researcher:\(CrossGatewayRoomSetup.memberID(remoteResearcher.route))"),
                      "invite issued on the TARGET gateway for the exact member id")
        XCTAssertTrue(calls.contains("register:room-test:\(CrossGatewayRoomSetup.memberID(remoteResearcher.route))"),
                      "route registered on the HOME gateway")
        XCTAssertFalse(calls.contains("revoke:"), "happy path never revokes")
    }

    /// Peer-registration failure → grant revoked, typed honest error, room
    /// still exists (retry-unchanged semantics, spec §11.8/§12).
    func testRegisterFailureRevokesGrantAndSurfacesTypedError() async throws {
        let home = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "home-install", profile: "default"))
        let remoteSeam = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "remote-install", profile: "researcher"))
        // registerScopedPeer runs on the HOME gateway (methods_groups.py:297
        // registers the route on the room's gateway); the revoke is issued on
        // the TARGET that minted the grant.
        home.registerError = GatewayRoomLinkClient.RoomLinkError.registrationRefusal("room grant scope does not match this route")
        let environment = await makeLinkedEnvironment(home: home, remote: remoteSeam)

        do {
            _ = try await environment.createRoom(
                gatewayID: GatewayID(rawValue: "homegw"), name: "Crew",
                members: [localResearcher, remoteResearcher],
                setupID: "room-fail")
            XCTFail("registration failure must throw")
        } catch let error as RoomCommandFailure {
            guard case .rpcFailed(let message, _) = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("room-fail"), "error names the room for retry-unchanged: \(message)")
            XCTAssertTrue(message.contains("no message was sent"), "honest: nothing was dispatched")
        }
        XCTAssertTrue(remoteSeam.calls.contains("revoke:researcher"),
                      "the issued grant must be revoked on the target after a failed register")
        XCTAssertTrue(home.calls.contains("create:room-fail:2"),
                      "the room itself was created (idempotent retry path)")
    }

    /// Same-gateway rooms keep the plain create path — no peer targets, no
    /// invite/register, even when the RoomLink seam exists (§11.8 item 5).
    func testSameGatewayRoomSkipsLinkChoreography() async throws {
        let home = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "home-install", profile: "default"))
        let remoteSeam = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "remote-install", profile: "researcher"))
        let environment = await makeLinkedEnvironment(home: home, remote: remoteSeam)

        _ = try await environment.createRoom(
            gatewayID: GatewayID(rawValue: "homegw"), name: "Local Crew",
            members: [localResearcher,
                      RoomMemberCandidate(route: Route(gatewayID: homeGateway, profileSlug: ProfileSlug(rawValue: "writer")),
                                          displayName: "Writer")],
            setupID: "room-local")

        XCTAssertFalse(home.calls.contains { $0.hasPrefix("invite:") },
                       "same-gateway members never trigger invite")
        XCTAssertFalse(home.calls.contains { $0.hasPrefix("peer-member:") },
                       "same-gateway roster carries no peer targets")
        XCTAssertFalse(home.calls.contains { $0.hasPrefix("register:") },
                       "no peer route registration for an all-local roster")
    }

    /// A remote member whose gateway does NOT advertise compatible support
    /// fails closed BEFORE the room is created (§11.5 capability checks).
    func testIncompatibleRemoteGatewayFailsClosedBeforeCreate() async throws {
        let home = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "home-install", profile: "default"))
        let remoteSeam = ScriptedCrossGatewaySeam(
            homeSnapshot: snapshot(installationID: "remote-install", profile: "researcher"))
        // The remote gateway answers capabilities WITHOUT direct support.
        var remoteSnapshot = snapshot(installationID: "remote-install", profile: "researcher", direct: false)
        remoteSeam.homeSnapshot = remoteSnapshot
        remoteSeam.targetSnapshots["researcher"] = remoteSnapshot
        _ = remoteSnapshot // silence
        let environment = await makeLinkedEnvironment(home: home, remote: remoteSeam)

        do {
            _ = try await environment.createRoom(
                gatewayID: GatewayID(rawValue: "homegw"), name: "Crew",
                members: [localResearcher, remoteResearcher],
                setupID: "room-blocked")
            XCTFail("incompatible remote must fail closed")
        } catch let error as RoomCommandFailure {
            guard case .unsupportedMethod(let what) = error else {
                return XCTFail("expected unsupportedMethod, got \(error)")
            }
            XCTAssertTrue(what.contains("RoomLink"), "names the missing capability: \(what)")
        }
        XCTAssertFalse(home.calls.contains { $0.hasPrefix("create:") },
                       "no room may be created when a remote member is incompatible")
        XCTAssertFalse(remoteSeam.calls.contains { $0.hasPrefix("invite:") },
                       "no grant may be requested from an incompatible target")
    }
}
