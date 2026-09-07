import XCTest
import FleetCore
@testable import FleetUI

/// TRUE BOTS MODE slice 5 VM tests (D19/D20/D22) — RoomLink negotiation and
/// flows, typed-failure copy surface completeness. The mention domain itself
/// is pinned in FleetCore's RoomLinkMentionsDomainTests.
final class RoomLinkViewModelTests: XCTestCase {

    // MARK: - Scripted seam

    /// Deterministic in-memory RoomLinkCommanding (actor — NSLock is banned
    /// in async contexts on this toolchain).
    actor ScriptedRoomLink: RoomLinkCommanding {
        var negotiation: RoomLinkNegotiation
        var inviteCalls: [Double] = []
        var registerCalls: [String] = []
        var revokeCalls: [String] = []
        var promoteConfirms: [Bool] = []
        var replicateCalls: Int = 0
        var replicaToServe: RoomReplicaState?
        var failPromote: Bool = false
        var failInvite: Bool = false

        init(negotiation: RoomLinkNegotiation) {
            self.negotiation = negotiation
        }

        func negotiate() async throws -> RoomLinkNegotiation { negotiation }

        func invite(roomID: String?, memberID: String?, ttlSeconds: Double) async throws -> RoomLinkGrant {
            if failInvite {
                throw RoomLinkRegistrationRefusal.grantScopeMismatch
            }
            inviteCalls.append(ttlSeconds)
            let now = Date()
            return RoomLinkGrant(
                id: "g-\(inviteCalls.count)", token: "tok-\(inviteCalls.count)-abcdefgh",
                roomID: roomID, memberID: memberID ?? "m-scripted",
                targetProfile: "researcher",
                permissions: RoomLinkGrant.Permission.allCases,
                issuedAt: now, expiresAt: now.addingTimeInterval(ttlSeconds))
        }

        func registerPeer(
            roomID: String, memberID: String, grant: RoomLinkGrant,
            targetURL: String, catalogDigest: String
        ) async throws -> RoomPeerRoute {
            registerCalls.append(memberID)
            return RoomPeerRoute(
                roomID: roomID, memberID: memberID,
                targetInstallID: "install-remote", targetProfile: grant.targetProfile,
                mode: "direct", transportSecurity: "tls", status: .ready)
        }

        func revoke(grant: RoomLinkGrant) async throws {
            revokeCalls.append(grant.token)
        }

        func peerRoutes(roomID: String) async throws -> [RoomPeerRoute] {
            [RoomPeerRoute(
                roomID: roomID, memberID: "m-scripted",
                targetInstallID: "install-remote", targetProfile: "researcher",
                mode: "direct", transportSecurity: "tls", status: .ready)]
        }

        func replicaState(roomID: String) async throws -> RoomReplicaState? {
            replicaToServe
        }

        func replicate(roomID: String) async throws -> RoomReplicateReceipt {
            replicateCalls += 1
            return RoomReplicateReceipt(
                roomID: roomID, storedSeq: 10, ingested: 4,
                authorityGatewayID: "install:local", authorityEpoch: 2,
                caughtUp: replicaToServe?.isCaughtUp ?? true)
        }

        func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt {
            promoteConfirms.append(confirm)
            if failPromote {
                throw RoomLinkRegistrationRefusal.grantScopeMismatch
            }
            return RoomPromotionReceipt(
                roomID: roomID, authorityGatewayID: "install:local", authorityEpoch: 4,
                previousGatewayID: "install:old", previousEpoch: 3,
                claimSeq: 11, latestSeq: 10)
        }

        func demote(roomID: String, observedGatewayID: String, observedEpoch: Int) async throws {}
    }

    private func supportedNegotiation(catalogDigest: String = String(repeating: "c", count: 64)) -> RoomLinkNegotiation {
        RoomLinkNegotiation(
            authorityGatewayID: "install:local",
            enabled: true,
            protocolVersion: 2,
            installationID: "local",
            linkModes: ["direct"],
            persistentProcess: true,
            textOnly: true,
            attachmentsSupported: false,
            catalogDigest: catalogDigest,
            executionPolicy: RoomLinkExecutionPolicy(
                version: 1, targetProfile: "default", enabledToolsets: ["bot_room"],
                approvalMode: "manual", maxIterations: 12,
                policyDigest: String(repeating: "p", count: 64)),
            endpoint: RoomLinkEndpoint(
                available: true, url: "https://roomlink.example.test/v1",
                transportSecurity: "tls"),
            methods: [
                "groups.capabilities", "groups.peer.invite", "groups.peer.register",
                "groups.peer.revoke", "groups.replica_state", "groups.replicate",
                "groups.promote", "groups.demote",
            ])
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

    @MainActor
    private func makeVM(seam: ScriptedRoomLink) -> RoomLinkViewModel {
        RoomLinkViewModel(room: makeRoom(), commands: seam)
    }

    // MARK: - Negotiation honesty (D19)

    @MainActor
    func testUnsupportedGatewayShowsHonestExplanationNeverFakeSupport() async throws {
        let seam = ScriptedRoomLink(negotiation: RoomLinkNegotiation(
            authorityGatewayID: "install:x",
            enabled: false,
            disabledReason: .durableRunStorageRequired))
        let vm = makeVM(seam: seam)
        await vm.start()

        XCTAssertEqual(
            vm.unsupportedExplanation,
            "Gateway storage setup needed before rooms can link across machines.")
        // No grant was ever minted on an unsupported gateway.
        let invites = await seam.inviteCalls
        XCTAssertTrue(invites.isEmpty)
    }

    @MainActor
    func testUnknownDisabledReasonPreservedVerbatim() async throws {
        let seam = ScriptedRoomLink(negotiation: RoomLinkNegotiation(
            authorityGatewayID: "install:x",
            enabled: false,
            disabledReason: .other("future_reason")))
        let vm = makeVM(seam: seam)
        await vm.start()
        XCTAssertEqual(
            vm.unsupportedExplanation,
            "This gateway can't link rooms across machines (future_reason).")
    }

    // MARK: - Grant lifecycle (D19)

    @MainActor
    func testInviteMintsGrantWithChosenTTLAndRegisterPublishesRoute() async throws {
        let seam = ScriptedRoomLink(negotiation: supportedNegotiation())
        let vm = makeVM(seam: seam)
        await vm.start()

        vm.setTTL(28800)
        let invited = await vm.invite()
        XCTAssertTrue(invited)
        let grant = try XCTUnwrap(vm.activeGrant)
        XCTAssertEqual(grant.targetProfile, "researcher")
        // TTL forwarded exactly.
        let inviteTTLCalls = await seam.inviteCalls
        XCTAssertEqual(inviteTTLCalls, [28800])

        let registered = await vm.registerPeer()
        XCTAssertTrue(registered)
        let registerCalls = await seam.registerCalls
        XCTAssertEqual(registerCalls, ["m-scripted"])
        // Route surfaced.
        XCTAssertEqual(vm.routes.first?.status, .ready)
        XCTAssertEqual(vm.routes.first?.transportSecurity, "tls")
    }

    @MainActor
    func testRevokeClearsGrant() async throws {
        let seam = ScriptedRoomLink(negotiation: supportedNegotiation())
        let vm = makeVM(seam: seam)
        await vm.start()
        await vm.invite()
        let revoked = await vm.revokeGrant()
        XCTAssertTrue(revoked)
        XCTAssertNil(vm.activeGrant)
        let revokeCalls = await seam.revokeCalls
        XCTAssertEqual(revokeCalls.count, 1)
    }

    @MainActor
    func testInviteBlockedOnTTLOutOfBoundsNeverFires() async throws {
        let seam = ScriptedRoomLink(negotiation: supportedNegotiation())
        let vm = makeVM(seam: seam)
        await vm.start()
        vm.setTTL(10) // Below upstream floor 60.
        let invited = await vm.invite()
        XCTAssertFalse(invited)
        XCTAssertEqual(
            vm.errorMessage, "ttl_seconds must be between 60 and 86400")
        let invites = await seam.inviteCalls
        XCTAssertTrue(invites.isEmpty, "out-of-bounds TTL never reaches the wire")
    }

    // MARK: - Replication / promotion (D19)

    @MainActor
    func testStaleReplicaBlocksPromotionAndReplayUnblocks() async throws {
        let seam = ScriptedRoomLink(negotiation: supportedNegotiation())
        await seam.setReplica(RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:local", authorityEpoch: 3,
            lastSeq: 4, latestSeq: 10, eventBytes: 2048, createdAt: 1, updatedAt: 2))
        let vm = makeVM(seam: seam)
        await vm.start()

        // Stale → blocked, honest explanation.
        XCTAssertFalse(vm.promotionReadiness.isReady)
        XCTAssertTrue(vm.promotionReadiness.confirmationMessage.contains("behind"))

        // Promotion while blocked → refused client-side, no wire call.
        let promotedBlocked = await vm.promote(confirmed: true)
        XCTAssertFalse(promotedBlocked)
        let noConfirms = await seam.promoteConfirms
        XCTAssertTrue(noConfirms.isEmpty)

        // Replay catches the replica up.
        await seam.setReplica(RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:local", authorityEpoch: 3,
            lastSeq: 10, latestSeq: 10, eventBytes: 4096, createdAt: 1, updatedAt: 2))
        let replayed = await vm.replicateNow()
        XCTAssertTrue(replayed)
        let replicateCalls = await seam.replicateCalls
        XCTAssertEqual(replicateCalls, 1)
        XCTAssertTrue(vm.promotionReadiness.isReady)
    }

    @MainActor
    func testPromoteRequiresExplicitConfirmationAndSendsConfirmTrue() async throws {
        let seam = ScriptedRoomLink(negotiation: supportedNegotiation())
        await seam.setReplica(RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:local", authorityEpoch: 3,
            lastSeq: 10, latestSeq: 10, eventBytes: 4096, createdAt: 1, updatedAt: 2))
        let vm = makeVM(seam: seam)
        await vm.start()

        // Unconfirmed → refused, NO wire call (upstream would 4118 anyway —
        // the client never fires it).
        let unconfirmed = await vm.promote(confirmed: false)
        XCTAssertFalse(unconfirmed)
        let noConfirms = await seam.promoteConfirms
        XCTAssertTrue(noConfirms.isEmpty)

        // Confirmed → confirm:true on the wire, receipt named.
        let promoted = await vm.promote(confirmed: true)
        XCTAssertTrue(promoted)
        let confirms = await seam.promoteConfirms
        XCTAssertEqual(confirms, [true])
        XCTAssertTrue(vm.notice?.contains("epoch 4") ?? false)
        XCTAssertTrue(vm.notice?.contains("install:old") ?? false)
    }

    // MARK: - Missing seam (honest absence)

    @MainActor
    func testMissingSeamRecordsHonestExplanation() async throws {
        let vm = RoomLinkViewModel(room: makeRoom(), commands: nil)
        await vm.start()
        XCTAssertEqual(
            vm.errorMessage,
            "No room connection is available on this gateway.")
        XCTAssertEqual(vm.attemptedWriteCount, 0)
    }

    // MARK: - D22 typed-failure copy completeness

    func testEveryFailureReasonHasTypedCopyAndActionsNeverGenericOnly() {
        // The card list from the mission (13 wire spellings): every one must
        // produce a distinct, specific copy + at least one action.
        let wireSpellings = [
            "provider_auth_or_access", "provider_quota_limit", "provider_rate_limit",
            "provider_server_error", "context_overflow", "missing_config",
            "model_unavailable", "runtime_offline", "queued_expired",
            "delivery_timeout", "target_busy", "agent_blocked", "cancelled", "unknown",
        ]
        var seenTitles = Set<String>()
        for spelling in wireSpellings {
            let reason = BotFailureReason(wireValue: spelling)
            let surface = BotFailureCopy.Surface(reason)
            // Distinct typed title per reason (unknown spellings degrade to
            // .unknown — still typed copy, not generic-only).
            if reason != .unknown {
                XCTAssertFalse(
                    seenTitles.contains(surface.title),
                    "duplicate title for \(spelling)")
                seenTitles.insert(surface.title)
            }
            XCTAssertFalse(surface.message.isEmpty)
            XCTAssertFalse(
                surface.actions.isEmpty,
                "\(spelling) must offer at least one recovery action")
        }
        // Wire spellings never leak through verbatim in user copy...
        XCTAssertFalse(
            BotFailureCopy.message(for: .providerAuthOrAccess)
                .contains("provider_auth_or_access"))
    }

    func testTypedFailureActionsMatchWireRecoverySemantics() {
        // context_overflow → compress_then_resume (never plain retry-first).
        XCTAssertEqual(BotFailureCopy.actions(for: .contextOverflow), [.compressThenResume])
        // provider_quota_limit → check quota (never auto-retry).
        XCTAssertEqual(BotFailureCopy.actions(for: .providerQuotaLimit), [.checkQuota])
        // runtime_offline → reconnect + retry.
        XCTAssertEqual(
            BotFailureCopy.actions(for: .runtimeOffline),
            [.reconnectRuntime, .retry])
        // Attention class surfaces persistent badge copy.
        XCTAssertTrue(BotFailureReason.providerAuthOrAccess.requiresAttention)
    }
}

extension RoomLinkViewModelTests.ScriptedRoomLink {
    func setReplica(_ replica: RoomReplicaState?) async {
        self.replicaToServe = replica
    }
}
