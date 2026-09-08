import XCTest
@testable import FleetCore
import Foundation

/// Bot Mode stabilization — regression tests for the manual RoomLink path:
/// - `RoomLinkCatalogValidation` fails closed on partial/synthetic catalogs
///   (the stale registerPeer defect).
/// - `RoomLinkNegotiation.protocolVersions` is a SET: membership gating,
///   never first-element equality; missing/empty list supports nothing.
/// - `RoomReplicator` submits VERBATIM authority-stamped pages with real
///   room identity (the placeholder-replicate defect) and fails on lineage
///   regressions / no-progress loops.
/// - `RoomLinkGrant` catalog round-trip (invite → register verbatim).
final class RoomLinkStabilizationTests: XCTestCase {

    // MARK: - Catalog validation (defect 1)

    /// A structurally complete catalog (all upstream _CATALOG_FIELDS).
    private static func completeCatalog(
        installationID: String = "install:remote"
    ) -> MetadataValue {
        .object([
            "installation_id": .string(installationID),
            "protocol_versions": .array([.number(2)]),
            "link_modes": .array([.string("direct")]),
            "persistent_process": .bool(true),
            "text": .bool(true),
            "attachments": .bool(false),
            "execution_policy": .object([
                "version": .number(1),
                "target_profile": .string("researcher"),
                "enabled_toolsets": .array([.string("bot_room")]),
                "approval_mode": .string("manual"),
                "max_iterations": .number(12),
                "policy_digest": .string(String(repeating: "p", count: 64)),
            ]),
            "catalog_digest": .string(String(repeating: "c", count: 64)),
            "endpoint": .object([
                "available": .bool(true),
                "url": .string("https://roomlink.example.test/v1"),
                "transport_security": .string("tls"),
            ]),
        ])
    }

    func testCatalogValidationAcceptsCompleteCatalog() {
        XCTAssertNil(RoomLinkCatalogValidation.validate(
            catalog: Self.completeCatalog(), targetProfile: "researcher"))
    }

    func testCatalogValidationFailsClosedOnMissingCatalog() {
        let refusal = RoomLinkCatalogValidation.validate(
            catalog: nil, targetProfile: "researcher")
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("catalog") ?? false)
    }

    func testCatalogValidationFailsClosedOnPartialCatalog() {
        // The stale-path two-field shape.
        let partial = MetadataValue.object([
            "installation_id": .string("install:remote"),
            "catalog_digest": .string(String(repeating: "c", count: 64)),
        ])
        let refusal = RoomLinkCatalogValidation.validate(
            catalog: partial, targetProfile: "researcher")
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("incomplete") ?? false)
    }

    func testCatalogValidationFailsClosedOnSyntheticInstallationIdentity() {
        // installation_id populated from the target PROFILE (the exact
        // stale-path fabrication) must be refused even when the rest of the
        // catalog is complete.
        let synthetic = Self.completeCatalog(installationID: "researcher")
        let refusal = RoomLinkCatalogValidation.validate(
            catalog: synthetic, targetProfile: "researcher")
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("synthetic") ?? false)
    }

    func testCatalogValidationFailsClosedOnEmptyProtocolVersions() {
        var fields: [String: MetadataValue] = [:]
        if case .object(let o) = Self.completeCatalog() { fields = o }
        fields["protocol_versions"] = .array([])
        let refusal = RoomLinkCatalogValidation.validate(
            catalog: .object(fields), targetProfile: "researcher")
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("protocol versions") ?? false)
    }

    func testCatalogValidationFailsClosedOnIncompletePolicy() {
        var fields: [String: MetadataValue] = [:]
        if case .object(let o) = Self.completeCatalog() { fields = o }
        fields["execution_policy"] = .object([
            "version": .number(1),
            "target_profile": .string("researcher"),
        ])
        let refusal = RoomLinkCatalogValidation.validate(
            catalog: .object(fields), targetProfile: "researcher")
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("execution policy") ?? false)
    }

    // MARK: - Protocol versions as a set (defect 3)

    func testProtocolVersionsMembershipNotFirstElement() {
        // Upstream advertises a LIST: [1, 2]. Compatibility for v2 must be
        // membership — never equality against the first element.
        let negotiation = RoomLinkNegotiation(
            authorityGatewayID: "install:x", enabled: true,
            protocolVersions: [1, 2], methods: [])
        XCTAssertTrue(negotiation.supportsProtocol(2))
        XCTAssertTrue(negotiation.supportsProtocol(1))
        XCTAssertFalse(negotiation.supportsProtocol(3))
        XCTAssertEqual(negotiation.highestProtocolVersion, 2)
    }

    func testProtocolVersionsFailClosedOnMissingOrEmpty() {
        let missing = RoomLinkNegotiation(
            authorityGatewayID: "install:x", enabled: true, methods: [])
        XCTAssertFalse(missing.supportsProtocol(2), "absent list supports nothing")
        let empty = RoomLinkNegotiation(
            authorityGatewayID: "install:x", enabled: true,
            protocolVersions: [], methods: [])
        XCTAssertFalse(empty.supportsProtocol(2), "empty list supports nothing")
    }

    func testCrossGatewayGatesUseMembership() {
        func fixture(_ versions: [Int]) -> RoomLinkTargetSnapshot {
            RoomLinkTargetSnapshot(
                negotiation: RoomLinkNegotiation(
                    authorityGatewayID: "install:x", enabled: true, profile: "default",
                    protocolVersions: versions, installationID: "remote",
                    linkModes: ["direct"], persistentProcess: true,
                    catalogDigest: String(repeating: "c", count: 64),
                    executionPolicy: RoomLinkExecutionPolicy(
                        version: 1, targetProfile: "default", enabledToolsets: ["bot_room"],
                        approvalMode: "manual", maxIterations: 12,
                        policyDigest: String(repeating: "p", count: 64)),
                    endpoint: RoomLinkEndpoint(
                        available: true, url: "https://roomlink.example.test/v1",
                        transportSecurity: "tls"),
                    methods: ["groups.create", "groups.state", "groups.peer.register",
                              "groups.peer.invite", "groups.peer.revoke"]),
                catalog: .object([:]), driver: true)
        }
        XCTAssertTrue(fixture([1, 2]).supportsDirect, "v2 anywhere in the list gates open")
        XCTAssertFalse(fixture([1]).supportsDirect, "no v2 → fail closed")
        XCTAssertFalse(fixture([]).supportsDirect, "empty list → fail closed")
    }

    // MARK: - Replicator choreography (defect 2)

    /// Scripted authority + sink capturing every replicate call.
    private final class ScriptedReplay: RoomReplaySourceProviding, @unchecked Sendable {
        var profile: RoomReplayProfile
        var pages: [RoomReplayLogPage]
        private(set) var logCalls: [(roomID: String, sinceSeq: Int)] = []
        private let lock = NSLock()
        init(profile: RoomReplayProfile, pages: [RoomReplayLogPage]) {
            self.profile = profile
            self.pages = pages
        }
        func roomProfile(roomID: String) async throws -> RoomReplayProfile {
            lock.withLock { profile }
        }
        func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage {
            lock.withLock { logCalls.append((roomID, sinceSeq)) }
            let index = lock.withLock { min(logCalls.count - 1, pages.count - 1) }
            return pages[max(0, index)]
        }
    }

    private final class CapturingSink: RoomReplicateSink, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(roomID: String, roomName: String, members: MetadataValue, page: MetadataValue)] = []
        /// Per-call caught_up answers (last value repeats when exhausted;
        /// default true = replica reports itself caught up).
        var caughtUpAnswers: [Bool] = []
        func replicate(
            roomID: String, roomName: String, members: MetadataValue, page: MetadataValue
        ) async throws -> RoomReplicateReceipt {
            try lock.withLock {
                let index = calls.count
                calls.append((roomID, roomName, members, page))
                let caughtUp = index < caughtUpAnswers.count
                    ? caughtUpAnswers[index]
                    : (caughtUpAnswers.last ?? true)
                return RoomReplicateReceipt(
                    roomID: roomID, storedSeq: 10, ingested: 1,
                    authorityGatewayID: "install:hub", authorityEpoch: 3, caughtUp: caughtUp)
            }
        }
    }

    private static func logPage(
        cursor: Int, latestSeq: Int = 10, hasMore: Bool = false,
        authorityID: String = "install:hub", epoch: Int = 3
    ) -> RoomReplayLogPage {
        RoomReplayLogPage(
            roomID: "room-alpha",
            page: .object([
                "events": .array([]),
                "cursor": .number(Double(cursor)),
                "latest_seq": .number(Double(latestSeq)),
                "has_more": .bool(hasMore),
                "authority": .object(["gateway_id": .string(authorityID), "epoch": .number(Double(epoch))]),
            ]),
            cursor: cursor, latestSeq: latestSeq, hasMore: hasMore,
            authorityGatewayID: authorityID, authorityEpoch: epoch)
    }

    private static var profile: RoomReplayProfile {
        RoomReplayProfile(
            roomID: "room-alpha", name: "Launch Crew",
            members: .array([
                .object(["member_id": .string("m-1"), "profile": .string("researcher")]),
            ]),
            authorityGatewayID: "install:hub", authorityEpoch: 3)
    }

    func testReplicatorSendsRealIdentityAndVerbatimPage() async throws {
        let page = Self.logPage(cursor: 10)
        let source = ScriptedReplay(profile: Self.profile, pages: [page])
        let sink = CapturingSink()
        let outcome = try await RoomReplicator.replicate(
            roomID: "room-alpha", replica: nil, source: source, sink: sink)
        XCTAssertEqual(sink.calls.count, 1)
        // REAL identity — never placeholders.
        XCTAssertEqual(sink.calls.first?.roomName, "Launch Crew")
        XCTAssertEqual(sink.calls.first?.members, Self.profile.members)
        // The page is forwarded VERBATIM (deep equality with the authority's page).
        XCTAssertEqual(sink.calls.first?.page, page.page)
        XCTAssertTrue(outcome.caughtUp)
        XCTAssertEqual(outcome.lastAuthorityEpoch, 3)
    }

    func testReplicatorPagesUntilCaughtUp() async throws {
        let page1 = Self.logPage(cursor: 5, latestSeq: 10, hasMore: true)
        let page2 = Self.logPage(cursor: 10)
        let source = ScriptedReplay(profile: Self.profile, pages: [page1, page2])
        let sink = CapturingSink()
        sink.caughtUpAnswers = [false, true]
        let outcome = try await RoomReplicator.replicate(
            roomID: "room-alpha", replica: nil, source: source, sink: sink)
        XCTAssertEqual(sink.calls.count, 2, "has_more pages until caught up")
        XCTAssertEqual(source.logCalls.map(\.sinceSeq), [0, 5])
        XCTAssertEqual(outcome.pages, 2)
    }

    func testReplicatorFailsOnEpochRegression() async throws {
        let page1 = Self.logPage(cursor: 5, latestSeq: 10, hasMore: true, epoch: 4)
        let page2 = Self.logPage(cursor: 10, epoch: 3)
        let source = ScriptedReplay(profile: Self.profile, pages: [page1, page2])
        let sink = CapturingSink()
        sink.caughtUpAnswers = [false, true]
        do {
            _ = try await RoomReplicator.replicate(
                roomID: "room-alpha", replica: nil, source: source, sink: sink)
            XCTFail("expected epoch regression failure")
        } catch let error as RoomReplicationFailure {
            guard case .epochRegression = error else {
                return XCTFail("unexpected failure: \\(error)")
            }
        }
    }

    func testReplicatorFailsOnAuthorityChangeMidReplay() async throws {
        let page1 = Self.logPage(cursor: 5, latestSeq: 10, hasMore: true)
        let page2 = Self.logPage(cursor: 10, authorityID: "install:other")
        let source = ScriptedReplay(profile: Self.profile, pages: [page1, page2])
        let sink = CapturingSink()
        sink.caughtUpAnswers = [false, true]
        do {
            _ = try await RoomReplicator.replicate(
                roomID: "room-alpha", replica: nil, source: source, sink: sink)
            XCTFail("expected authority-change failure")
        } catch let error as RoomReplicationFailure {
            guard case .authorityChangedMidReplay = error else {
                return XCTFail("unexpected failure: \\(error)")
            }
        }
    }

    func testReplicatorFailsOnNoProgressLoop() async throws {
        // Page says has_more but the receipt never reports caught up and the
        // cursor never advances — the choreography must stop honestly.
        struct NoProgressSource: RoomReplaySourceProviding {
            let profile: RoomReplayProfile
            func roomProfile(roomID: String) async throws -> RoomReplayProfile { profile }
            func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage {
                RoomReplayLogPage(
                    roomID: "room-alpha",
                    page: .object([
                        "events": .array([]), "cursor": .number(Double(5)),
                        "latest_seq": .number(Double(10)), "has_more": .bool(true),
                        "authority": .object(["gateway_id": .string("install:hub"), "epoch": .number(Double(3))]),
                    ]),
                    cursor: 5, latestSeq: 10, hasMore: true,
                    authorityGatewayID: "install:hub", authorityEpoch: 3)
            }
        }
        let source = NoProgressSource(profile: RoomReplayProfile(
            roomID: "room-alpha", name: "Launch Crew",
            members: .array([.object(["member_id": .string("m-1")])]),
            authorityGatewayID: "install:hub", authorityEpoch: 3))
        let sink = CapturingSink()
        sink.caughtUpAnswers = [false]
        do {
            _ = try await RoomReplicator.replicate(
                roomID: "room-alpha", replica: nil, source: source, sink: sink)
            XCTFail("expected no-progress failure")
        } catch let error as RoomReplicationFailure {
            guard case .noProgress = error else {
                return XCTFail("unexpected failure: \\(error)")
            }
        }
    }

    func testReplicatorFailsClosedOnIncompleteProfile() async throws {
        let badProfile = RoomReplayProfile(
            roomID: "room-alpha", name: "", members: .array([]),
            authorityGatewayID: "install:hub", authorityEpoch: 3)
        let source = ScriptedReplay(profile: badProfile, pages: [Self.logPage(cursor: 10)])
        let sink = CapturingSink()
        do {
            _ = try await RoomReplicator.replicate(
                roomID: "room-alpha", replica: nil, source: source, sink: sink)
            XCTFail("expected incomplete-profile failure")
        } catch let error as RoomReplicationFailure {
            guard case .incompleteRoomProfile = error else {
                return XCTFail("unexpected failure: \\(error)")
            }
        }
        XCTAssertTrue(sink.calls.isEmpty, "no wire call with placeholder identity")
    }

    func testReplicatorResumesFromReplicaLastSeq() async throws {
        let replica = RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:hub", authorityEpoch: 3,
            lastSeq: 7, latestSeq: 10, eventBytes: 2048, createdAt: 1, updatedAt: 2)
        let source = ScriptedReplay(profile: Self.profile, pages: [Self.logPage(cursor: 10)])
        let sink = CapturingSink()
        _ = try await RoomReplicator.replicate(
            roomID: "room-alpha", replica: replica, source: source, sink: sink)
        XCTAssertEqual(source.logCalls.first?.sinceSeq, 7, "paging resumes at the replica's stored seq")
    }

    // MARK: - Grant catalog round-trip (defect 1)

    func testGrantCarriesCatalogForVerbatimRegistration() {
        let grant = RoomLinkGrant(
            id: "g", token: "tok", roomID: "r", memberID: "m",
            targetProfile: "researcher", permissions: [.status],
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(60),
            catalog: Self.completeCatalog(),
            endpointURL: "https://roomlink.example.test/v1")
        XCTAssertNil(RoomLinkCatalogValidation.validate(
            catalog: grant.catalog, targetProfile: grant.targetProfile))
        XCTAssertEqual(grant.endpointURL, "https://roomlink.example.test/v1")
    }
}
