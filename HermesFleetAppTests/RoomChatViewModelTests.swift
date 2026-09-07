import XCTest
import FleetCore
import FleetUI

/// TRUE BOTS MODE slice 4 (D15/D16/D18) — RoomChatViewModel over scripted
/// command + driver-status seams: capability gating (disabled mutations
/// NEVER issue writes), replay-first transcript survival, D16 controls, and
/// source-qualified member rows.
@MainActor
final class RoomChatViewModelTests: XCTestCase {

    // MARK: Test doubles

    /// Records every write; replays a scripted log.
    private actor SpyCommands: RoomChatCommanding {
        var sendCount = 0
        var renameCount = 0
        var disbandCount = 0
        var stopCount = 0
        var retryCount = 0
        var approveChoices: [String] = []
        private(set) var events: [HostedRoomEventValue] = []

        func seed(_ events: [HostedRoomEventValue]) { self.events = events }

        func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
            RoomLogPageSlice(
                events: events.filter { $0.seq > sinceSeq },
                cursor: events.map(\.seq).max() ?? 0,
                latestSeq: events.map(\.seq).max() ?? 0,
                hasMore: false,
                authorityGatewayID: "workstation",
                authorityEpoch: 1)
        }

        func send(roomID: String, text: String, threadID: String?) async throws -> Int {
            sendCount += 1
            let seq = (events.map(\.seq).max() ?? 0) + 1
            events.append(HostedRoomEventValue(
                roomID: roomID, seq: seq, eventID: "s-\(seq)", kind: "message.user",
                actorKind: "user", actorID: "user", payloadText: text,
                createdAt: Date().timeIntervalSince1970))
            return seq
        }

        func rename(roomID: String, name: String) async throws { renameCount += 1 }

        func disband(roomID: String) async throws { disbandCount += 1 }

        func stop(roomID: String) async throws -> Int {
            stopCount += 1
            return 2
        }

        func retry(roomID: String, taskID: String) async throws { retryCount += 1 }

        func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws {
            approveChoices.append(choice)
        }

        func createRoom(name: String, members: [[String: String]]) async throws -> String {
            "room-new"
        }
    }

    private struct StubDriverStatus: RoomDriverStatusProviding {
        var status: RoomDriverStatus?
        func driverStatus(roomID: String) async throws -> RoomDriverStatus? { status }
    }

    // MARK: Fixtures

    private func hostedRoom(
        methods: [String]? = [
            "groups.create", "groups.send", "groups.rename", "groups.log",
            "groups.disband", "groups.stop", "groups.retry", "groups.approve",
        ]
    ) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "workstation"), key: "room-alpha"),
            name: "Launch Crew",
            members: [
                FleetRoomMember(name: "Researcher", handle: "researcher"),
                FleetRoomMember(name: "Default", handle: "default"),
            ],
            hosted: HostedRoomState(
                authorityGatewayID: "workstation",
                authorityEpoch: 1,
                advertisedMethods: methods,
                driverAvailable: true))
    }

    private func legacyRoom() -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: .desktopLegacy, gatewayID: GatewayID(rawValue: "workstation"), key: "name:Research Crew"),
            name: "Research Crew",
            members: [FleetRoomMember(name: "Researcher")],
            recentLog: [
                FleetRoomMessage(
                    id: "l1",
                    from: .init(kind: .member, name: "Researcher"),
                    text: "Older room managed from Desktop.",
                    at: 1_757_100_000_000),
            ])
    }

    private func makeCommands() -> SpyCommands {
        let commands = SpyCommands()
        let base = Date().timeIntervalSince1970
        var events: [HostedRoomEventValue] = []
        for (seq, text) in ["one", "two"].enumerated() {
            events.append(HostedRoomEventValue(
                roomID: "room-alpha", seq: seq + 1, eventID: "e-\(seq + 1)",
                kind: "message.member", actorKind: "member", actorID: "researcher",
                payloadText: text, createdAt: base))
        }
        // willing: true
        return commands
    }

    // MARK: Capability gating — disabled mutations NEVER issue writes

    func testLegacyRoomSendsAreBlockedWithoutWrites() async throws {
        let commands = makeCommands()
        await commands.seed([
            HostedRoomEventValue(
                roomID: "room-alpha", seq: 1, eventID: "e-1", kind: "message.member",
                actorKind: "member", actorID: "researcher", payloadText: "hi",
                createdAt: 1_757_000_000)
        ])
        let vm = RoomChatViewModel(room: legacyRoom(), commands: commands, driverStatus: nil)

        let sent = await vm.send("hello")
        XCTAssertFalse(sent, "send blocked on legacy room")
        let renamed = await vm.rename("New Name")
        XCTAssertFalse(renamed, "rename blocked on legacy room")
        let disbanded = await vm.disband()
        XCTAssertFalse(disbanded, "disband blocked on legacy room")
        _ = await vm.stopWorking()
        _ = await vm.retry(taskID: "t1")

        XCTAssertEqual(vm.attemptedWriteCount, 0, "capability-disabled mutations NEVER issue writes")
        XCTAssertNotNil(vm.disabledExplanation, "honest disabled explanation recorded")
        let sendCount = await commands.sendCount
        XCTAssertEqual(sendCount, 0)
    }

    func testHostedRoomWithoutMethodsIssuesNoWrites() async throws {
        // Old gateway: hosted room that advertises nothing (observational).
        let commands = makeCommands()
        let vm = RoomChatViewModel(
            room: hostedRoom(methods: ["groups.log"]),
            commands: commands, driverStatus: nil)

        _ = await vm.send("hello")
        _ = await vm.rename("x")
        _ = await vm.disband()
        XCTAssertEqual(vm.attemptedWriteCount, 0, "no writes without advertised methods")
    }

    // MARK: Replay-first transcript + survival

    func testTranscriptProjectsFromReplayAndSurvivesReentry() async throws {
        let commands = makeCommands()
        await commands.seed([
            HostedRoomEventValue(
                roomID: "room-alpha", seq: 1, eventID: "e-1", kind: "message.member",
                actorKind: "member", actorID: "researcher", payloadText: "first",
                createdAt: 1_757_000_000),
            HostedRoomEventValue(
                roomID: "room-roomID", seq: 2, eventID: "e-2", kind: "message.member",
                actorKind: "member", actorID: "default", payloadText: "second",
                createdAt: 1_757_000_001),
        ])
        let vm = RoomChatViewModel(room: hostedRoom(), commands: commands, driverStatus: nil)
        await vm.start()

        XCTAssertEqual(vm.transcript.count, 2, "both log events project to rows")
        XCTAssertEqual(vm.transcript.map(\.text), ["first", "second"], "seq order preserved")

        // Navigation survival: a NEW VM over the same room replays the same
        // durable log from scratch (cursor 0) and renders the same rows.
        let vm2 = RoomChatViewModel(room: hostedRoom(), commands: commands, driverStatus: nil)
        await vm2.start()
        XCTAssertEqual(vm2.transcript.count, 2, "transcript survives navigation via replay")
    }

    func testSendAppendsToTranscriptAfterRefresh() async throws {
        let commands = makeCommands()
        let vm = RoomChatViewModel(room: hostedRoom(), commands: commands, driverStatus: nil)
        await vm.start()

        let sent = await vm.send("slice four")
        XCTAssertTrue(sent)
        XCTAssertEqual(vm.attemptedWriteCount, 1)
        XCTAssertTrue(
            vm.transcript.contains { $0.text == "slice four" },
            "sent message lands in the transcript after replay refresh")
    }

    // MARK: D16 controls

    func testStopRetryApproveRideCommandSeam() async throws {
        let commands = makeCommands()
        let approval = RoomPendingApproval(
            memberID: "researcher", taskID: "task-1", executionGeneration: 1,
            requestID: "req-1", approval: ["prompt": .string("Run the tool?")])
        let status = RoomDriverStatus(
            working: true, blocked: true, counts: ["queued": 1],
            pendingRetries: [RoomPendingRetry(taskID: "task-9")],
            pendingApprovals: [approval])
        let vm = RoomChatViewModel(
            room: hostedRoom(), commands: commands,
            driverStatus: StubDriverStatus(status: status))
        await vm.start()

        XCTAssertTrue(vm.driverWorking)
        XCTAssertEqual(vm.pendingApprovals.map(\.taskID), ["task-1"])

        let stopped = await vm.stopWorking()
        XCTAssertTrue(stopped)
        let stopCount = await commands.stopCount
        XCTAssertEqual(stopCount, 1)

        let retried = await vm.retry(taskID: "task-9")
        XCTAssertTrue(retried)
        let retryCount = await commands.retryCount
        XCTAssertEqual(retryCount, 1)

        let approved = await vm.approve(approval, choice: "once")
        XCTAssertTrue(approved)
        let choices = await commands.approveChoices
        XCTAssertEqual(choices, ["once"])
        XCTAssertEqual(vm.attemptedWriteCount, 3)
    }

    // MARK: Rename + disband state

    func testRenameUpdatesRoomNameAndDisbandTombstones() async throws {
        let commands = makeCommands()
        let vm = RoomChatViewModel(room: hostedRoom(), commands: commands, driverStatus: nil)
        await vm.start()

        let renamed = await vm.rename("Renamed Crew")
        XCTAssertTrue(renamed)
        XCTAssertEqual(vm.roomName, "Renamed Crew")

        let disbanded = await vm.disband()
        XCTAssertTrue(disbanded)
        XCTAssertTrue(vm.isDisbanded)
    }

    // MARK: D18 source-qualified members

    func testMemberRowsCarrySourceQualifier() async throws {
        let vm = RoomChatViewModel(room: hostedRoom(), commands: nil, driverStatus: nil)
        let rows = vm.memberRows(gatewayLabel: "Workstation")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(
            rows.allSatisfy { !$0.source.isEmpty },
            "every member chip carries a non-empty source qualifier (gateway label)")
        XCTAssertTrue(
            rows.contains { $0.source.contains("Workstation") },
            "gateway label rides alongside the member name")
    }

    // MARK: Legacy bounded window

    func testLegacyRoomProjectsBoundedRecentLogOnly() async throws {
        let vm = RoomChatViewModel(room: legacyRoom(), commands: nil, driverStatus: nil)
        await vm.start()
        XCTAssertEqual(vm.transcript.count, 1, "bounded recentLog window projects")
        XCTAssertEqual(vm.transcript.first?.text, "Older room managed from Desktop.")
        XCTAssertFalse(vm.capabilities.canSend, "legacy room never claims send capability")
    }

    // MARK: No seam = honest failure, no crash

    func testMissingSeamRecordsHonestExplanation() async throws {
        let vm = RoomChatViewModel(room: hostedRoom(), commands: nil, driverStatus: nil)
        await vm.start()
        // Can't replay without a seam but must not crash; send records honest copy.
        _ = await vm.send("hello")
        XCTAssertEqual(vm.attemptedWriteCount, 0)
        XCTAssertNotNil(vm.disabledExplanation)
    }
}
