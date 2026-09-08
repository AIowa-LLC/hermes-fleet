import XCTest
@testable import FleetCore

final class BotCompletionTests: XCTestCase {
    private let a = GatewayID(rawValue: "gateway-a")
    private let b = GatewayID(rawValue: "gateway-b")
    private func candidate(_ gateway: GatewayID, _ name: String, title: String? = nil) -> MentionCandidate {
        MentionCandidate(route: Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: name)), friendlyTitle: title ?? name)
    }

    func testDuplicateNamesAndGatewayLabelsHaveDistinctResolvableAliases() {
        let roster = [candidate(a, "researcher"), candidate(b, "researcher")]
        let current = candidate(a, "default").route
        let results = BotConversationMentions.suggestions(query: "", roster: roster, excluding: current, gatewayLabel: { _ in "Same Label" })
        XCTAssertEqual(Set(results.map(\.alias)).count, 2)
        for result in results {
            let draft = BotConversationMentions.prepare(text: "@\(result.alias) investigate", roster: roster, current: current, gatewayLabel: { _ in "Same Label" })
            XCTAssertTrue(draft.text.contains(result.id.id))
            XCTAssertTrue(draft.text.hasPrefix("@\(result.alias) investigate"))
            XCTAssertTrue(draft.text.contains("never forward"))
        }
        let ambiguous = BotConversationMentions.prepare(text: "@researcher investigate", roster: roster, current: current, gatewayLabel: { _ in "Same Label" })
        XCTAssertEqual(ambiguous.text, "@researcher investigate")
        XCTAssertNotNil(ambiguous.notice)
    }

    // MARK: - Friendly duplicate aliases (stabilization defect 4)

    /// Preferred hierarchy: unique name → bare tag; duplicate across
    /// gateways → tag + gateway label (@researcher-mac / @researcher-4090),
    /// NOT a giant route-hex string.
    func testDuplicateAliasesUseFriendlyGatewayLabelsNotHex() {
        let roster = [candidate(a, "researcher"), candidate(b, "researcher")]
        let current = candidate(a, "default").route
        let labels = [a: "Mac Mini", b: "4090 Box"]
        let results = BotConversationMentions.suggestions(
            query: "", roster: roster, excluding: current,
            gatewayLabel: { labels[$0] ?? $0.rawValue })
        let aliases = Set(results.map(\.alias))
        XCTAssertEqual(aliases, ["researcher-mac-mini", "researcher-4090-box"])
        // No alias ever contains a long hex blob (the old defect appended
        // the full hex encoding of the route id — 60+ chars).
        for alias in aliases {
            XCTAssertLessThan(alias.count, 40, "alias must stay friendly: \(alias)")
            XCTAssertFalse(alias.contains(where: { $0.isHexDigit && $0.isNumber && alias.count > 30 }))
        }
    }

    /// Unique names keep their bare tag (tier 1) — no qualifier noise.
    func testUniqueNamesKeepBareAlias() {
        let roster = [candidate(a, "researcher"), candidate(b, "ops")]
        let current = candidate(a, "default").route
        let results = BotConversationMentions.suggestions(
            query: "", roster: roster, excluding: current,
            gatewayLabel: { $0 == a ? "Mac Mini" : "4090 Box" })
        XCTAssertEqual(Set(results.map(\.alias)), ["researcher", "ops"])
    }

    /// Tier 3: same tag AND same gateway label (same-name profiles on one
    /// gateway) → short deterministic suffix; aliases stay unique,
    /// deterministic across calls, and resolvable to exactly one route.
    func testSameLabelCollisionGetsShortDeterministicSuffix() {
        let roster = [candidate(a, "researcher"), candidate(b, "researcher")]
        let current = candidate(a, "default").route
        let results = BotConversationMentions.suggestions(
            query: "", roster: roster, excluding: current,
            gatewayLabel: { _ in "Hub" })
        let aliases = results.map(\.alias)
        XCTAssertEqual(Set(aliases).count, 2, "aliases remain unique")
        for alias in aliases {
            XCTAssertTrue(alias.hasPrefix("researcher-hub-"), "tier-3 alias: \(alias)")
            // Short deterministic suffix: 5 base36 chars.
            let suffix = String(alias.dropFirst("researcher-hub-".count))
            XCTAssertEqual(suffix.count, 5)
            XCTAssertTrue(suffix.allSatisfy { $0.isLetter || $0.isNumber })
        }
        // Deterministic: a second call yields the identical aliases.
        let again = BotConversationMentions.suggestions(
            query: "", roster: roster, excluding: current,
            gatewayLabel: { _ in "Hub" })
        XCTAssertEqual(again.map(\.alias), aliases)
        // Reversible: each alias resolves to exactly one route via prepare().
        for result in results {
            let draft = BotConversationMentions.prepare(
                text: "@\(result.alias) go", roster: roster, current: current,
                gatewayLabel: { _ in "Hub" })
            XCTAssertTrue(draft.text.contains(result.id.id),
                          "alias resolves to exactly its route")
        }
    }

    /// The tier-2 alias must never collide silently with a DIFFERENT bot's
    /// bare tag (a bot actually named "researcher-mac"): prepare() reports
    /// ambiguity rather than dispatching to the wrong route.
    func testQualifiedAliasCollidingWithAnotherBareTagStaysUnambiguous() {
        let roster = [
            candidate(a, "researcher"),                      // tier-2: researcher-mac-mini
            candidate(b, "researcher"),                      // tier-2: researcher-4090-box
            candidate(a, "researcher-mac-mini"),             // bare tag researcher-mac-mini
        ]
        let current = candidate(a, "default").route
        let labels = [a: "Mac Mini", b: "4090 Box"]
        let results = BotConversationMentions.suggestions(
            query: "", roster: roster, excluding: current,
            gatewayLabel: { labels[$0] ?? $0.rawValue })
        // All aliases still unique...
        XCTAssertEqual(Set(results.map(\.alias)).count, 3)
        // ...and the colliding token resolves to nothing (ambiguous), never
        // to the wrong bot.
        let draft = BotConversationMentions.prepare(
            text: "@researcher-mac-mini go", roster: roster, current: current,
            gatewayLabel: { labels[$0] ?? $0.rawValue })
        XCTAssertNotNil(draft.notice, "collision surfaces a notice, not a wrong dispatch")
    }

    func testRenamedSelfExclusionAndGatewaySearch() {
        let selfBot = candidate(a, "default")
        let teammate = candidate(b, "ops", title: "Research Buddy")
        let results = BotConversationMentions.suggestions(query: "Laptop", roster: [selfBot, teammate], excluding: selfBot.route, gatewayLabel: { _ in "Laptop" })
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.alias, "research-buddy")
    }

    func testMultipleMentionsAndMissingTargetsNeverForwardText() {
        let current = candidate(a, "default").route
        let roster = [candidate(a, "research"), candidate(a, "review")]
        let draft = BotConversationMentions.prepare(text: "@research ask @review for an opinion", roster: roster, current: current, gatewayLabel: { $0.rawValue })
        XCTAssertTrue(draft.text.hasPrefix("@research ask @review for an opinion"))
        XCTAssertTrue(draft.text.contains("message_agent_target"))
        XCTAssertTrue(draft.text.contains("compose your own message"))
        let missing = BotConversationMentions.prepare(text: "@missing hello", roster: [], current: current, gatewayLabel: { $0.rawValue })
        XCTAssertEqual(missing.text, "@missing hello")
        XCTAssertNotNil(missing.notice)
    }

    func testAutocompleteOnlyReplacesActiveTokenAndIgnoresEmail() {
        XCTAssertEqual(BotConversationMentions.query(in: "ask @"), "")
        XCTAssertNil(BotConversationMentions.query(in: "ops@example.com"))
        XCTAssertEqual(BotConversationMentions.inserting("research", into: "ask @res"), "ask @research ")
    }

    func testCanonicalCommandsCompactOnlyExactCommands() {
        for text in ["/new", " /reset\n"] {
            XCTAssertEqual(BotConversationDraft.protectingCanonical(text, isCanonical: true).text, "/compact")
            XCTAssertEqual(BotConversationDraft.protectingCanonical(text, isCanonical: false).text, text)
        }
        XCTAssertEqual(BotConversationDraft.protectingCanonical("/new extra", isCanonical: true).text, "/new extra")
        XCTAssertEqual(BotModeContract.canonicalChatTitle, "Bot Chat")
    }

    func testAvatarFlagSurvivesRosterMappingAndIdentityFallback() {
        let descriptor = ProfileDescriptor(name: "researcher", path: "/fixture/researcher", hasAvatar: true)
        XCTAssertTrue(FleetBot.bot(on: a, descriptor: descriptor).hasAvatar)
        XCTAssertEqual(BotAvatarIdentity.face(hasAvatar: true, shape: "hexagon", identityName: "researcher"), .image)
        XCTAssertEqual(BotAvatarIdentity.face(hasAvatar: false, shape: nil, identityName: ""), .initials)
        XCTAssertEqual(BotAvatarIdentity.parseBlobShape("blobatar::cloud", fallbackSeed: "researcher"), .blob(seed: "researcher", kind: "cloud"))
    }
}

extension BotCompletionTests {
    func testStructuredSchedulesAndRawPreservation() {
        let date = Date(timeIntervalSince1970: 0)
        func value(_ mode: BotRoutineSchedule.Mode, raw: String = "") -> String? {
            BotRoutineSchedule.value(mode: mode, date: date, hour: 9, minute: 30, weekday: 1, intervalHours: 2, raw: raw)
        }
        XCTAssertEqual(value(.once), "1970-01-01T00:00:00Z")
        XCTAssertEqual(value(.hourly), "every 2h")
        XCTAssertEqual(value(.daily), "30 9 * * *")
        XCTAssertEqual(value(.weekly), "30 9 * * 1")
        XCTAssertEqual(value(.custom, raw: "  in 45m  "), "  in 45m  ")
    }

    func testHiddenActivityRequiresActualSignalAndNeverUnhides() {
        var bot = FleetBot(route: candidate(a, "researcher").route, displayName: "Researcher",
                           botModeMetadata: BotModeMetadata(hidden: true))
        XCTAssertFalse(HiddenBotActivity.hasSignal(bot))
        bot.activity = .working
        XCTAssertTrue(HiddenBotActivity.hasSignal(bot))
        XCTAssertEqual(bot.botModeMetadata?.hidden, true)
        bot.botModeMetadata?.hidden = false
        XCTAssertFalse(HiddenBotActivity.hasSignal(bot))
    }
}
