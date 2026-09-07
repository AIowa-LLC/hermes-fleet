import XCTest
@testable import FleetCore

/// Slice 2 domain tests: sections registry, roster presentation, profile
/// management outcomes, duplicate naming, avatar identity, delete gating.
final class BotManagementDomainTests: XCTestCase {

    // MARK: - Sections registry

    func testSectionsNormalizeDropsBlankAndDuplicateIDs() {
        let value = MetadataValue.array([
            .object(["id": .string("s1"), "name": .string("Clients")]),
            .object(["id": .string("  "), "name": .string("Blank id")]),
            .object(["id": .string("s2"), "name": .string("")]),
            .object(["id": .string("s1"), "name": .string("Dup")]),
            .object(["id": .string("s3"), "name": .string("Research")]),
            .string("garbage"),
        ])
        let sections = BotSectionRegistry.normalize(value)
        XCTAssertEqual(sections.map(\.id), ["s1", "s3"])
        XCTAssertEqual(sections.map(\.name), ["Clients", "Research"])
    }

    func testSectionsNonArrayDecodesEmpty() {
        XCTAssertTrue(BotSectionRegistry.normalize(.string("nope")).isEmpty)
        XCTAssertTrue(BotSectionRegistry.normalize(nil).isEmpty)
    }

    func testSectionsRoundTripEncodeNormalize() {
        let sections = [
            BotSection(id: "sec-a", name: "Alpha"),
            BotSection(id: "sec-b", name: "Beta"),
        ]
        let encoded = BotSectionRegistry.encode(sections)
        XCTAssertEqual(BotSectionRegistry.normalize(encoded), sections)
    }

    func testSectionsSplitEveryRowExactlyOnceUnknownIDUnassigned() {
        let sections = [BotSection(id: "s1", name: "Clients"), BotSection(id: "s2", name: "Ops")]
        let rows = [
            ("bot-a", "s1"),
            ("bot-b", "s2"),
            ("bot-c", nil),
            ("bot-d", "s-gone"),  // registry lost this section → unassigned
        ]
        let blocks = BotSectionRegistry.split(rows, sectionID: { $0.1 }, sections: sections)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].id, "s1")
        XCTAssertEqual(blocks[0].rows.map(\.0), ["bot-a"])
        XCTAssertEqual(blocks[1].id, "s2")
        XCTAssertEqual(blocks[1].rows.map(\.0), ["bot-b"])
        // Unassigned block is LAST and carries both the never-assigned row
        // and the unknown-section row — nothing is dropped, nothing invented.
        XCTAssertTrue(blocks[2].isUnassigned)
        XCTAssertEqual(Set(blocks[2].rows.map(\.0)), Set(["bot-c", "bot-d"]))
    }

    func testSectionsDeleteNeverDeletesBots() {
        // Deleting a section only changes the registry; split then files its
        // former members under unassigned (upstream semantics).
        let before = [BotSection(id: "s1", name: "Clients")]
        let after: [BotSection] = []
        let rows = [("bot-a", "s1")]
        let blocksBefore = BotSectionRegistry.split(rows, sectionID: { $0.1 }, sections: before)
        XCTAssertEqual(blocksBefore[0].rows.count, 1)
        let blocksAfter = BotSectionRegistry.split(rows, sectionID: { $0.1 }, sections: after)
        XCTAssertEqual(blocksAfter.count, 1)
        XCTAssertTrue(blocksAfter[0].isUnassigned)
        XCTAssertEqual(blocksAfter[0].rows.count, 1)
    }

    func testSectionsNewIDShape() {
        let id = BotSectionRegistry.newSectionID(now: 1_700_000_000)
        XCTAssertTrue(id.hasPrefix("sec-"))
        XCTAssertNotEqual(id, BotSectionRegistry.newSectionID(now: 1_700_000_000))
    }

    func testSectionsRenderGate() {
        XCTAssertFalse(BotSectionRegistry.rendersSections([]))
        XCTAssertTrue(BotSectionRegistry.rendersSections([BotSection(id: "s", name: "S")]))
    }

    // MARK: - Roster presentation

    private func makeBot(
        slug: String, gateway: String = "gw1", title: String? = nil,
        hidden: Bool? = nil, pinned: Bool? = nil,
        canonical: CanonicalSessionRef? = nil,
        last: SessionSummary? = nil,
        activity: BotActivity = .unknown
    ) -> FleetBot {
        var metadata: BotModeMetadata? = BotModeMetadata(title: title, hidden: hidden, pinned: pinned)
        if title == nil && hidden == nil && pinned == nil { metadata = nil }
        return FleetBot(
            route: Route(gatewayID: GatewayID(rawValue: gateway), profileSlug: ProfileSlug(rawValue: slug)),
            displayName: slug.replacingOccurrences(of: "-", with: " ").capitalized,
            activity: activity,
            latestSession: last,
            canonicalSession: canonical,
            botModeMetadata: metadata
        )
    }

    func testActivityAnchorPrefersFresherOfCanonicalAndLatest() {
        let old = makeBot(
            slug: "a",
            canonical: CanonicalSessionRef(id: "c1", preview: "canonical", lastActive: 100),
            last: SessionSummary(id: "l1", title: "t", preview: "latest", startedAt: 900)
        )
        let anchor = BotRosterPresentation.activityAnchor(for: old)
        XCTAssertEqual(anchor.source, .latestSession)
        XCTAssertEqual(anchor.lastActive, 900)
        XCTAssertEqual(anchor.preview, "latest")

        let canonicalNewer = makeBot(
            slug: "b",
            canonical: CanonicalSessionRef(id: "c2", preview: "canon", lastActive: 950),
            last: SessionSummary(id: "l2", title: "t", preview: "late", startedAt: 100)
        )
        let anchor2 = BotRosterPresentation.activityAnchor(for: canonicalNewer)
        XCTAssertEqual(anchor2.source, .canonicalBotChat)
        XCTAssertEqual(anchor2.lastActive, 950)
    }

    func testOrderPinnedFirstThenRecencyThenRoute() {
        let pinnedOld = makeBot(slug: "z-old", pinned: true, last: SessionSummary(id: "1", title: "t", startedAt: 10))
        let fresh = makeBot(slug: "m-fresh", last: SessionSummary(id: "2", title: "t", startedAt: 999))
        let stale = makeBot(slug: "a-stale", last: SessionSummary(id: "3", title: "t", startedAt: 5))
        let none = makeBot(slug: "none")
        let ordered = BotRosterPresentation.order([stale, none, fresh, pinnedOld])
        XCTAssertEqual(ordered.map(\.profileSlug.rawValue), ["z-old", "m-fresh", "a-stale", "none"])
    }

    func testActiveNowRequiresLiveSignalAndNotHidden() {
        XCTAssertTrue(BotRosterPresentation.isActiveNow(makeBot(slug: "w", activity: .working)))
        XCTAssertTrue(BotRosterPresentation.isActiveNow(makeBot(slug: "t", activity: .thinking)))
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeBot(slug: "i", activity: .idle)))
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeBot(slug: "u", activity: .unknown)))
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeBot(slug: "h", hidden: true, activity: .working)))
    }

    func testHiddenExcludedByDefaultRevealedOnRequest() {
        let visible = makeBot(slug: "v")
        let hidden = makeBot(slug: "h", hidden: true)
        let bots = [visible, hidden]
        XCTAssertEqual(BotRosterPresentation.visible(bots).map(\.profileSlug.rawValue), ["v"])
        XCTAssertEqual(Set(BotRosterPresentation.visible(bots, revealingHidden: true).map(\.profileSlug.rawValue)), Set(["v", "h"]))
    }

    func testDuplicateNameDisambiguationLabelsSharedTitlesOnly() {
        let a = makeBot(slug: "researcher", gateway: "gw1", title: "Research")
        let b = makeBot(slug: "researcher", gateway: "gw2", title: "Research")
        let c = makeBot(slug: "other", gateway: "gw1")
        let labels = BotRosterPresentation.duplicateNameRoutes([a, b, c]) { id in id.rawValue.uppercased() }
        XCTAssertEqual(labels[a.route], "GW1")
        XCTAssertEqual(labels[b.route], "GW2")
        XCTAssertNil(labels[c.route])
    }

    func testSearchMatchesTitleSlugRouteDescriptionPreviewGateway() {
        let bot = makeBot(slug: "researcher", gateway: "gw1", title: "Deep Research")
        var described = bot
        described.profileDescription = "Finds papers"
        described.canonicalSession = CanonicalSessionRef(id: "c", preview: "latest synthesis attached", lastActive: 1)
        func m(_ q: String) -> Bool {
            BotRosterPresentation.matches(bot, query: q, gatewayLabel: "Workstation") ||
            BotRosterPresentation.matches(described, query: q, gatewayLabel: "Workstation")
        }
        XCTAssertTrue(m("deep"))
        XCTAssertTrue(m("RESEARCH"))
        XCTAssertTrue(m("researcher"))
        XCTAssertTrue(m("gw1"))
        XCTAssertTrue(m("papers"))
        XCTAssertTrue(m("synthesis"))
        XCTAssertTrue(m("workstation"))
        XCTAssertTrue(m(""))
        XCTAssertFalse(m("zebra"))
    }

    func testOwnerStatusFromPresence() {
        XCTAssertEqual(BotRosterPresentation.ownerStatus(presence: .reachable), .online)
        XCTAssertEqual(BotRosterPresentation.ownerStatus(presence: .unreachable), .offlineGhost)
        XCTAssertEqual(BotRosterPresentation.ownerStatus(presence: .unknown), .unknown)
    }

    // MARK: - Edit outcome (P3 partial-success)

    func testEditOutcomePartialSuccessReportsAppliedAndFailedSections() {
        let edit = BotProfileEdit(
            metadata: BotModeMetadata(title: "New"),
            metadataExpectedRevision: 3,
            soul: "updated soul",
            descriptionText: "updated desc",
            model: "big-model",
            provider: "nous",
            disabledSkills: ["x"],
            enabledToolsets: ["t"],
            enabledMCPServers: ["m"]
        )
        let outcome = BotProfileEditOutcome(
            edit: edit,
            applied: ["ui_meta": true, "soul": true, "description": true,
                      "model": false, "skills": true, "toolsets": false, "mcp_servers": true]
        )
        XCTAssertEqual(outcome.appliedSections, [.metadata, .soul, .description, .skills, .mcpServers])
        XCTAssertEqual(outcome.failedSections, [.model, .toolsets])
        XCTAssertFalse(outcome.succeeded)
    }

    func testEditOutcomeUntouchedSectionNeverReported() {
        // Only the metadata section was carried; a gateway reporting other
        // applied flags must not surface them as failures (or successes).
        let edit = BotProfileEdit(metadata: BotModeMetadata(title: "T"), metadataExpectedRevision: 1)
        let outcome = BotProfileEditOutcome(edit: edit, applied: ["ui_meta": true, "soul": true])
        XCTAssertEqual(outcome.appliedSections, [.metadata])
        XCTAssertTrue(outcome.failedSections.isEmpty)
        XCTAssertTrue(outcome.succeeded)
    }

    func testEditIsEmptyAndModelOnlyResend() {
        XCTAssertTrue(BotProfileEdit().isEmpty)
        let edit = BotProfileEdit(metadata: BotModeMetadata(title: "T"), model: "m2", provider: "p")
        XCTAssertFalse(edit.isEmpty)
        XCTAssertTrue(edit.hasModelSection)
        let resend = edit.modelOnlyResend
        XCTAssertNil(resend.metadata)
        XCTAssertEqual(resend.model, "m2")
        XCTAssertEqual(resend.provider, "p")
        XCTAssertFalse(resend.hasModelSection == false)
    }

    // MARK: - Duplicate naming

    func testDuplicateNamingFirstFreeSlot() {
        XCTAssertEqual(
            BotDuplicateNaming.candidateName(base: "researcher", occupiedNames: ["researcher"]),
            "researcher-2")
        XCTAssertEqual(
            BotDuplicateNaming.candidateName(base: "researcher", occupiedNames: ["researcher", "researcher-2", "researcher-3"]),
            "researcher-4")
        XCTAssertNil(BotDuplicateNaming.candidateName(base: "  ", occupiedNames: []))
    }

    func testDuplicateNamingTruncatesBaseNeverSuffix() {
        let long = String(repeating: "a", count: 80)
        let candidate = BotDuplicateNaming.candidateName(base: long, occupiedNames: [long])!
        XCTAssertEqual(candidate.count, 64)
        XCTAssertTrue(candidate.hasSuffix("-2"))
        XCTAssertEqual(candidate.dropLast(2).count, 62)
    }

    // MARK: - Avatar identity

    func testAvatarDefaultShapeDeterministic() {
        let a = BotAvatarIdentity.defaultShape(forName: "researcher")
        let b = BotAvatarIdentity.defaultShape(forName: "researcher")
        XCTAssertEqual(a, b)
        XCTAssertTrue(BotAvatarIdentity.defaultShapes.contains(a))
        // Different names can land anywhere — determinism is the contract.
        _ = BotAvatarIdentity.defaultShape(forName: "writer")
    }

    func testAvatarFaceClassification() {
        XCTAssertEqual(BotAvatarIdentity.face(hasAvatar: true, shape: nil, identityName: "x"), .image)
        XCTAssertEqual(
            BotAvatarIdentity.face(hasAvatar: false, shape: "hexagon", identityName: "x"),
            .shape("hexagon"))
        XCTAssertEqual(
            BotAvatarIdentity.face(hasAvatar: false, shape: nil, identityName: "x"),
            .initials)
        XCTAssertEqual(
            BotAvatarIdentity.face(hasAvatar: false, shape: "blobatar", identityName: "sam"),
            .blob(seed: "sam", kind: nil))
        XCTAssertEqual(
            BotAvatarIdentity.face(hasAvatar: false, shape: "blobatar:abc:cloud", identityName: "sam"),
            .blob(seed: "abc", kind: "cloud"))
    }

    // MARK: - Delete gate

    func testDeleteGateDefaultsOffWithExplanation() {
        guard case .unsupported = BotDeleteGate.currentGatewayGeneration else {
            return XCTFail("current generation must gate delete off")
        }
        XCTAssertFalse(
            BotDeleteGate.currentGatewayGeneration.explanation.isEmpty)
    }
}
