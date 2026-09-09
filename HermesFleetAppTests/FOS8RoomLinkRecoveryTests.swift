import XCTest
import FleetUI
import FleetCore

/// FOS-8 (t_1775f2c2) — RoomLink recovery inspector view-model tests:
/// fencing-assertion gate before promote, exact-lineage capture and
/// controlled demote, readback after both promote and demote, grants never
/// in labels/diagnostics.
@MainActor
final class FOS8RoomLinkRecoveryTests: XCTestCase {

    // MARK: - Scripted seam (records calls; serves deterministic lineage)

    private actor RecoverySeam: RoomLinkCommanding, RoomReplaySourceProviding, RoomReplicateSink {
        var negotiation: RoomLinkNegotiation
        private var replicaValue: RoomReplicaState?
        private(set) var promoteConfirms: [Bool] = []
        private(set) var demoteCalls: [(roomID: String, gatewayID: String, epoch: Int)] = []
        private(set) var replicaStateCallCount = 0

        init(negotiation: RoomLinkNegotiation, replica: RoomReplicaState?) {
            self.negotiation = negotiation
            self.replicaValue = replica
        }

        func setReplica(_ replica: RoomReplicaState?) { replicaValue = replica }

        // RoomReplaySourceProviding / RoomReplicateSink stubs (unused here).
        func roomProfile(roomID: String) async throws -> RoomReplayProfile {
            RoomReplayProfile(roomID: roomID, name: "", members: .array([]), authorityGatewayID: "install:hub", authorityEpoch: 3)
        }
        func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage {
            RoomReplayLogPage(roomID: roomID, page: .object([:]), cursor: 0, latestSeq: 0, hasMore: false, authorityGatewayID: "install:hub", authorityEpoch: 3)
        }
        func replicate(roomID: String, roomName: String, members: MetadataValue, page: MetadataValue) async throws -> RoomReplicateReceipt {
            RoomReplicateReceipt(roomID: roomID, storedSeq: 0, ingested: 0, authorityGatewayID: "install:hub", authorityEpoch: 3, caughtUp: true)
        }

        func negotiate() async throws -> RoomLinkNegotiation { negotiation }

        func invite(roomID: String?, memberID: String?, ttlSeconds: Double) async throws -> RoomLinkGrant {
            let now = Date()
            return RoomLinkGrant(
                id: "g-1", token: "tok-secret-abcdef", roomID: roomID,
                memberID: memberID ?? "m-1", targetProfile: "researcher",
                permissions: RoomLinkGrant.Permission.allCases,
                issuedAt: now, expiresAt: now.addingTimeInterval(ttlSeconds))
        }

        func registerPeer(roomID: String, memberID: String, grant: RoomLinkGrant, targetURL: String) async throws -> RoomPeerRoute {
            RoomPeerRoute(roomID: roomID, memberID: memberID, targetInstallID: "install-remote", targetProfile: "researcher", mode: "direct", transportSecurity: "tls")
        }

        func revoke(grant: RoomLinkGrant) async throws {}
        func peerRoutes(roomID: String) async throws -> [RoomPeerRoute] { [] }

        func replicaState(roomID: String) async throws -> RoomReplicaState? {
            replicaStateCallCount += 1
            return replicaValue
        }

        func roomReplaySource(roomID: String) async throws -> any RoomReplaySourceProviding { self }
        func replicateSink() async throws -> any RoomReplicateSink { self }

        func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt {
            promoteConfirms.append(confirm)
            return RoomPromotionReceipt(
                roomID: roomID,
                authorityGatewayID: "install:local", authorityEpoch: 4,
                previousGatewayID: "install:hub", previousEpoch: 3,
                claimSeq: 11, latestSeq: 10)
        }

        func demote(roomID: String, observedGatewayID: String, observedEpoch: Int) async throws {
            demoteCalls.append((roomID, observedGatewayID, observedEpoch))
        }
    }

    // MARK: - Fencing gate

    private func supportedNegotiation() -> RoomLinkNegotiation {
        RoomLinkNegotiation(
            authorityGatewayID: "install:local",
            enabled: true,
            protocolVersions: [2],
            installationID: "local",
            linkModes: ["direct"],
            persistentProcess: true,
            textOnly: true,
            attachmentsSupported: false,
            catalogDigest: String(repeating: "c", count: 64),
            methods: ["groups.capabilities", "groups.promote", "groups.demote",
                      "groups.replica_state", "groups.replicate"])
    }

    /// A caught-up replica of a FOREIGN authority — promotable state.
    private func foreignReplica() -> RoomReplicaState {
        RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:hub", authorityEpoch: 3,
            lastSeq: 10, latestSeq: 10, eventBytes: 2048,
            createdAt: 1_780_000_000, updatedAt: 1_780_000_100)
    }

    private func makeRoom() -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(
                provenance: .hosted,
                gatewayID: GatewayID(rawValue: "workstation"),
                key: "room-alpha"),
            name: "Launch Crew",
            hosted: HostedRoomState(
                authorityGatewayID: "install:local", authorityEpoch: 3,
                advertisedMethods: ["groups.send"], driverAvailable: true))
    }

    // MARK: - Fencing gate

    func testPromoteRefusedWithoutOperatorFencingAssertion() async throws {
        let seam = RecoverySeam(negotiation: supportedNegotiation(), replica: foreignReplica())
        let vm = RoomLinkViewModel(room: makeRoom(), commands: seam)
        await vm.start()

        // Confirmed but NOT fencing-asserted: refused client-side, zero wire calls.
        let refused = await vm.promote(confirmed: true)
        XCTAssertFalse(refused)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("fenced") == true,
                      "error explains the fencing assertion gate (got: \(vm.errorMessage ?? ""))")
        let confirms = await seam.promoteConfirms
        XCTAssertTrue(confirms.isEmpty, "no groups.promote fired without the assertion")
    }

    func testPromoteProceedsWithFencingAssertionAndRecordsReadback() async throws {
        let seam = RecoverySeam(negotiation: supportedNegotiation(), replica: foreignReplica())
        let vm = RoomLinkViewModel(room: makeRoom(), commands: seam)
        await vm.start()

        vm.operatorAssertedFencing = true
        let promoted = await vm.promote(confirmed: true)
        XCTAssertTrue(promoted)
        let confirms = await seam.promoteConfirms
        XCTAssertEqual(confirms, [true], "promote fired exactly once with confirm true")

        // Lineage recorded verbatim from the receipt.
        XCTAssertEqual(vm.lastPromotionReceipt?.authorityGatewayID, "install:local")
        XCTAssertEqual(vm.lastPromotionReceipt?.authorityEpoch, 4)
        XCTAssertEqual(vm.lastPromotionReceipt?.previousGatewayID, "install:hub")
        XCTAssertEqual(vm.lastPromotionReceipt?.previousEpoch, 3)

        // Readback performed (replica_state re-read after the operation).
        let calls = await seam.replicaStateCallCount
        XCTAssertGreaterThanOrEqual(calls, 3,
            "refresh + immediate recheck + post-promote readback all read replica state (got \(calls))")
    }

    // MARK: - Exact-lineage demote

    func testDemoteUsesExactObservedLineageAndReadsBack() async throws {
        let seam = RecoverySeam(negotiation: supportedNegotiation(), replica: foreignReplica())
        let vm = RoomLinkViewModel(room: makeRoom(), commands: seam)
        await vm.start()

        XCTAssertEqual(vm.observedLineage?.gatewayID, "install:hub",
                       "refresh captures the exact observed authority")
        XCTAssertEqual(vm.observedLineage?.epoch, 3)

        let demoted = await vm.demote()
        XCTAssertTrue(demoted)
        let calls = await seam.demoteCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.gatewayID, "install:hub",
                       "demote sends the EXACT observed authority gateway")
        XCTAssertEqual(calls.first?.epoch, 3, "demote sends the EXACT observed epoch")
        XCTAssertEqual(calls.first?.roomID, "room-alpha")

        // Readback after demote.
        let reads = await seam.replicaStateCallCount
        XCTAssertGreaterThanOrEqual(reads, 3, "pre-check + readback + refresh read state (got \(reads))")
    }

    func testDemoteRefusedWhenNoReplicaStateObservable() async throws {
        let seam = RecoverySeam(negotiation: supportedNegotiation(), replica: nil)
        let vm = RoomLinkViewModel(room: makeRoom(), commands: seam)
        await vm.start()

        let refused = await vm.demote()
        XCTAssertFalse(refused)
        XCTAssertTrue(vm.errorMessage?.contains("lineage") == true
                      || vm.errorMessage?.contains("replica") == true,
                      "honest no-lineage explanation (got: \(vm.errorMessage ?? ""))")
        let calls = await seam.demoteCalls
        XCTAssertTrue(calls.isEmpty, "no demote fired without observed lineage")
    }

    // MARK: - Grants never in labels or diagnostics

    func testGrantTokenNeverSurfacesInVMStateOrNotices() async throws {
        let seam = RecoverySeam(negotiation: supportedNegotiation(), replica: nil)
        let vm = RoomLinkViewModel(room: makeRoom(), commands: seam)
        await vm.start()

        await vm.setTTL(3600)
        await vm.invite()
        let granted = await vm.activeGrant
        XCTAssertNotNil(granted, "grant minted")

        let token = granted?.token ?? ""
        XCTAssertFalse(token.isEmpty)
        XCTAssertFalse(vm.notice?.contains(token) == true,
                       "notice never carries the raw grant token")
        XCTAssertFalse(vm.errorMessage?.contains(token) == true)
        // Masked rendering only.
        XCTAssertEqual(granted?.displayToken, "••••\(String(token.suffix(6)))")
    }
}
