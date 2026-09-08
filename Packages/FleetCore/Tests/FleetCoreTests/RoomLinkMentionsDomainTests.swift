import XCTest
@testable import FleetCore

/// TRUE BOTS MODE slice 5 domain tests (D19/D20/D22).
///
/// Pins the exact upstream semantics:
/// - mentionNameForms / botHandle / botMentionTag (data.ts:953-1015)
/// - parseGroupChatMentions (group-rounds.ts:45-90): @everyone/@all/@user,
///   collapsed-form matching, unknown pass-through
/// - groupMemberKey source qualification `gateway::slug` (group-membership)
/// - emails never become tags
/// - duplicate disambiguation: bare form poisoned on collision, qualified
///   handle resolves
/// - RoomLink negotiation / grants / promotion readiness / registration
///   refusals (methods_groups.py + hosted_room_peer.py at originally derived from 08b140d; re-verified against upstream main 966637323e, 2026-09-08)
final class RoomLinkMentionsDomainTests: XCTestCase {

    // MARK: - D20 mention forms (data.ts parity)

    func testMentionNameFormsSlugAndCollapsed() {
        // data.identity.test.ts:89-90
        XCTAssertEqual(MentionResolution.nameForms("Research Buddy"), ["research-buddy", "researchbuddy"])
        XCTAssertEqual(MentionResolution.nameForms("Ops"), ["ops"])
    }

    func testMentionNameFormsReservedTokensDropped() {
        // data.identity.test.ts:94-96: 'Hermes'/'@everyone' rename attempts
        // can never hijack the primary alias.
        XCTAssertEqual(MentionResolution.nameForms("Hermes"), [])
        XCTAssertEqual(MentionResolution.nameForms("@everyone"), [])
        XCTAssertEqual(MentionResolution.nameForms("everyone"), [])
        XCTAssertEqual(MentionResolution.nameForms("default"), [])
        XCTAssertEqual(MentionResolution.nameForms("all"), [])
        XCTAssertEqual(MentionResolution.nameForms("user"), [])
        XCTAssertEqual(MentionResolution.nameForms(""), [])
        XCTAssertEqual(MentionResolution.nameForms(nil), [])
    }

    func testBotHandlePrimaryAliasIsHermes() {
        // data.ts:953-962 — the word "default" never surfaces in the UI.
        XCTAssertEqual(MentionResolution.handle(name: "default", rosterHandle: nil), "hermes")
        XCTAssertEqual(MentionResolution.handle(name: "researcher", rosterHandle: nil), "researcher")
        XCTAssertEqual(MentionResolution.handle(name: "dixie", rosterHandle: "dixie-mac-mini"), "dixie-mac-mini")
    }

    func testMentionTagPrefersFriendlyForm() {
        // botMentionTag: first friendly form, else the profile handle.
        XCTAssertEqual(
            MentionResolution.mentionTag(friendlyTitle: "Research Buddy", name: "prof-1", handle: nil),
            "research-buddy")
        XCTAssertEqual(
            MentionResolution.mentionTag(friendlyTitle: "", name: "default", handle: nil),
            "hermes")
    }

    // MARK: - D20 token parsing (group-rounds.ts parity)

    func testMentionTokensRegexParity() {
        let text = "hey @dixie-mac-mini can you check @Ops and @everyone plus @user"
        let tokens = MentionResolution.mentionTokens(in: text)
        XCTAssertEqual(tokens, ["dixie-mac-mini", "Ops", "everyone", "user"])
    }

    func testParseResolvesCollapsedAndHandleForms() {
        let candidates = [
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "mac-mini"), profileSlug: ProfileSlug(rawValue: "dixie")),
                friendlyTitle: "Dixie", handle: "dixie-mac-mini"),
        ]
        let parsed = MentionResolution.parse(
            text: "hey @dixie-mac-mini can you check disk space",
            candidates: candidates,
            gatewayLabel: { _ in "mac-mini" })
        // Source-qualified key `mac-mini::dixie` (group-membership parity).
        XCTAssertEqual(parsed.mentioned, ["mac-mini::dixie"])
        XCTAssertTrue(parsed.unknownTokens.isEmpty)
    }

    func testParseEveryoneAndUserFlags() {
        let parsed = MentionResolution.parse(
            text: "@everyone ping @user and @all",
            candidates: [],
            gatewayLabel: { _ in "?" })
        XCTAssertTrue(parsed.everyone)
        XCTAssertTrue(parsed.mentioned.isEmpty)
        XCTAssertTrue(parsed.unknownTokens.isEmpty)
    }

    func testUnknownTokensPassThroughUnchanged() {
        let parsed = MentionResolution.parse(
            text: "ping @ghost-bot please",
            candidates: [],
            gatewayLabel: { _ in "?" })
        XCTAssertTrue(parsed.mentioned.isEmpty)
        XCTAssertEqual(parsed.unknownTokens, ["ghost-bot"])
    }

    func testEmailAddressesAreNeverTags() {
        // `ops@example.com`: the @ sits after token chars — not a token start.
        let text = "email ops@example.com now"
        XCTAssertEqual(MentionResolution.mentionTokens(in: text), [])
        // A candidate named "example.com" must still NOT match — there is no
        // token to resolve.
        let candidates = [
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "example.com")),
                friendlyTitle: "Example", handle: nil),
        ]
        let parsed = MentionResolution.parse(
            text: text, candidates: candidates, gatewayLabel: { _ in "workstation" })
        XCTAssertTrue(parsed.mentioned.isEmpty)
    }

    func testDuplicateBareNamesRequireQualifiedHandle() {
        // Two `dixie` bots on two gateways: the bare form is poisoned;
        // only `mac-mini::dixie` resolves (cross-connection test parity).
        let candidates = [
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "dixie")),
                friendlyTitle: "Dixie", handle: nil),
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "mac-mini"), profileSlug: ProfileSlug(rawValue: "dixie")),
                friendlyTitle: "Dixie", handle: "dixie-mac-mini"),
        ]
        func label(_ id: GatewayID) -> String { id.rawValue }

        // Bare @dixie does NOT resolve (ambiguous).
        var parsed = MentionResolution.parse(
            text: "hey @dixie", candidates: candidates, gatewayLabel: label)
        XCTAssertTrue(parsed.mentioned.isEmpty)
        XCTAssertEqual(parsed.unknownTokens, ["dixie"])

        // NOTE: the `gateway::slug` form can never be TYPED as a token — the
        // upstream mention charset `[a-z0-9._-]` has no `:` — so the typed
        // disambiguated form is the roster handle @name-device:
        parsed = MentionResolution.parse(
            text: "hey @dixie-mac-mini", candidates: candidates, gatewayLabel: label)
        XCTAssertEqual(parsed.mentioned, ["mac-mini::dixie"])

        // The other duplicate's handle-less bare form stays poisoned.
        parsed = MentionResolution.parse(
            text: "hey @dixie @dixie", candidates: candidates, gatewayLabel: label)
        XCTAssertTrue(parsed.mentioned.isEmpty)
    }

    func testUniqueBareNameMatchesDirectly() {
        let candidates = [
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "researcher")),
                friendlyTitle: "Research Buddy", handle: nil),
        ]
        let parsed = MentionResolution.parse(
            text: "@research-buddy and @researcher both work",
            candidates: candidates, gatewayLabel: { _ in "workstation" })
        XCTAssertEqual(parsed.mentioned, ["workstation::researcher"])
    }

    // MARK: - D20 autocomplete

    func testAutocompleteRanksAndQualifies() {
        let candidates = [
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "researcher")),
                friendlyTitle: "Research Buddy", handle: nil),
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "mac-mini"), profileSlug: ProfileSlug(rawValue: "dixie")),
                friendlyTitle: "Dixie", handle: nil),
        ]
        let suggestions = MentionResolution.autocomplete(
            query: "re", candidates: candidates,
            gatewayLabel: { $0.rawValue })
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.insertText, "research-buddy")

        // Empty query lists all candidates with bare (unambiguous) tags.
        let all = MentionResolution.autocomplete(
            query: "", candidates: candidates, gatewayLabel: { $0.rawValue })
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.insertText)), ["research-buddy", "dixie"])
    }

    func testAutocompleteDisambiguatesDuplicatesWithSourceQualifier() {
        let candidates = [
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "dixie")),
                friendlyTitle: "Dixie", handle: nil),
            MentionCandidate(
                route: Route(gatewayID: GatewayID(rawValue: "mac-mini"), profileSlug: ProfileSlug(rawValue: "dixie")),
                friendlyTitle: "Dixie", handle: nil),
        ]
        let suggestions = MentionResolution.autocomplete(
            query: "di", candidates: candidates, gatewayLabel: { $0.rawValue })
        XCTAssertEqual(suggestions.count, 2)
        // @name-gateway disambiguation (upstream @name-device rule).
        XCTAssertEqual(
            Set(suggestions.map(\.insertText)),
            ["dixie-workstation", "dixie-mac-mini"])
        // Both carry the gateway qualifier sublabel.
        XCTAssertTrue(suggestions.allSatisfy { $0.qualifier != nil })
    }

    // MARK: - D19 RoomLink negotiation

    func testDisabledReasonDecodesWireValues() {
        XCTAssertEqual(
            RoomLinkDisabledReason(wireValue: "durable_run_storage_required"),
            .durableRunStorageRequired)
        XCTAssertEqual(
            RoomLinkDisabledReason(wireValue: "gateway_roomlink_secret_unavailable"),
            .gatewayRoomlinkSecretUnavailable)
        // Unknown reason preserved verbatim.
        XCTAssertEqual(
            RoomLinkDisabledReason(wireValue: "future_reason"),
            .other("future_reason"))
    }

    func testNegotiationGatesOnAdvertisedMethods() {
        let negotiation = RoomLinkNegotiation(
            authorityGatewayID: "install:abc",
            enabled: true,
            protocolVersions: [2],
            installationID: "abc",
            linkModes: ["direct"],
            persistentProcess: true,
            catalogDigest: String(repeating: "a", count: 64),
            methods: ["groups.peer.invite", "groups.peer.register"])
        XCTAssertTrue(negotiation.supports("groups.peer.invite"))
        XCTAssertFalse(negotiation.supports("groups.promote"))
        XCTAssertTrue(negotiation.supportsDirectMode)
        XCTAssertEqual(
            negotiation.transportSummary,
            "Direct link · text only")
    }

    func testCatalogUnchangedFailsClosedOnDigestDrift() {
        let a = RoomLinkNegotiation(
            authorityGatewayID: "install:abc", enabled: true,
            catalogDigest: String(repeating: "a", count: 64))
        let b = RoomLinkNegotiation(
            authorityGatewayID: "install:abc", enabled: true,
            catalogDigest: String(repeating: "b", count: 64))
        XCTAssertFalse(RoomLinkNegotiation.catalogUnchanged(advertised: a, observed: b))
        XCTAssertTrue(RoomLinkNegotiation.catalogUnchanged(advertised: a, observed: a))
        // Empty digest is not proof of anything — fail closed.
        let empty = RoomLinkNegotiation(authorityGatewayID: "x", enabled: true)
        XCTAssertFalse(RoomLinkNegotiation.catalogUnchanged(advertised: empty, observed: empty))
    }

    // MARK: - D19 grants

    func testGrantTTLEnforcesUpstreamBounds() {
        XCTAssertNil(RoomLinkGrant.validate(ttlSeconds: 3600))
        XCTAssertEqual(
            RoomLinkGrant.validate(ttlSeconds: 30),
            "ttl_seconds must be between 60 and 86400")
        XCTAssertEqual(
            RoomLinkGrant.validate(ttlSeconds: 90000),
            "ttl_seconds must be between 60 and 86400")
    }

    func testGrantValidityAndNearExpiry() {
        let now = Date()
        let grant = RoomLinkGrant(
            id: "g1", token: "abcdefghijklmnop", roomID: "room-alpha", memberID: "m1",
            targetProfile: "researcher",
            permissions: [.approve, .dispatch, .status, .stop],
            issuedAt: now.addingTimeInterval(-3600), expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(grant.isValid(at: now))
        XCTAssertFalse(grant.isValid(at: now.addingTimeInterval(120)))
        // 60s remaining of 3660s ≈ 1.6% — inside the last 10% window.
        XCTAssertTrue(grant.isNearExpiry(at: now))
        // Token never renders in full (last 6 chars only).
        XCTAssertEqual(grant.displayToken, "••••klmnop")
    }

    // MARK: - D19 promotion prerequisites

    func testPromotionReadinessGates() {
        let local = "install:local"
        // Caught-up replica of a FOREIGN authority → ready, naming the
        // foreign gateway as the previous authority (upstream promote_replica
        // proceeds exactly here; the foreign gateway is previous_gateway at
        // epoch+1). Takeover is OF a foreign authority, never of self.
        let ready = RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:other", authorityEpoch: 3,
            lastSeq: 10, latestSeq: 10, eventBytes: 4096, createdAt: 1, updatedAt: 2)
        let readiness = RoomPromotionReadiness.evaluate(replica: ready, localAuthorityGatewayID: local)
        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(
            readiness.confirmationTitle,
            "Take over this room from install:other (epoch 3)?")

        // Stale foreign replica → NOT ready (forking hazard).
        let stale = RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: "install:other", authorityEpoch: 3,
            lastSeq: 4, latestSeq: 10, eventBytes: 4096, createdAt: 1, updatedAt: 2)
        let staleReadiness = RoomPromotionReadiness.evaluate(replica: stale, localAuthorityGatewayID: local)
        XCTAssertFalse(staleReadiness.isReady)
        XCTAssertTrue(staleReadiness.confirmationMessage.contains("behind"))

        // This gateway IS the authority → upstream refuses promote with
        // "this gateway already holds the room authority" — honest blocked
        // state, never offered as ready.
        let alreadyLocal = RoomReplicaState(
            roomID: "room-alpha", name: "Launch Crew",
            authorityGatewayID: local, authorityEpoch: 3,
            lastSeq: 10, latestSeq: 10, eventBytes: 4096, createdAt: 1, updatedAt: 2)
        let localReadiness = RoomPromotionReadiness.evaluate(replica: alreadyLocal, localAuthorityGatewayID: local)
        XCTAssertFalse(localReadiness.isReady)
        XCTAssertNil(localReadiness.confirmationTitle)
        XCTAssertTrue(localReadiness.confirmationMessage.contains("already holds the room authority"))

        // No replica state → unknown. Local identity missing → unknown too
        // (readiness can never be established without knowing self).
        XCTAssertEqual(
            RoomPromotionReadiness.evaluate(replica: nil, localAuthorityGatewayID: local),
            .unknown)
        XCTAssertEqual(
            RoomPromotionReadiness.evaluate(replica: ready, localAuthorityGatewayID: nil),
            .unknown)
    }

    // MARK: - D19 registration refusals (exact upstream strings)

    func testRegistrationRefusalDecodesExactWireStrings() {
        XCTAssertEqual(
            RoomLinkRegistrationRefusal(wireMessage: "target does not support RoomLink protocol v2"),
            .targetProtocolUnsupported)
        XCTAssertEqual(
            RoomLinkRegistrationRefusal(wireMessage: "target does not support a direct RoomLink"),
            .directModeUnsupported)
        XCTAssertEqual(
            RoomLinkRegistrationRefusal(wireMessage: "target capability catalog changed during setup"),
            .catalogChangedDuringSetup)
        XCTAssertEqual(
            RoomLinkRegistrationRefusal(wireMessage: "room grant scope does not match this route"),
            .grantScopeMismatch)
        XCTAssertNil(RoomLinkRegistrationRefusal(wireMessage: "something else"))
    }

    // MARK: - D19 replica progress

    func testReplicaProgressAndCaughtUp() {
        let replica = RoomReplicaState(
            roomID: "r", name: "n", authorityGatewayID: "a", authorityEpoch: 1,
            lastSeq: 5, latestSeq: 10, eventBytes: 1, createdAt: 0, updatedAt: 0)
        XCTAssertFalse(replica.isCaughtUp)
        XCTAssertEqual(replica.progress, 0.5, accuracy: 0.0001)
        let caughtUp = RoomReplicaState(
            roomID: "r", name: "n", authorityGatewayID: "a", authorityEpoch: 1,
            lastSeq: 10, latestSeq: 10, eventBytes: 1, createdAt: 0, updatedAt: 0)
        XCTAssertTrue(caughtUp.isCaughtUp)
        XCTAssertEqual(caughtUp.progress, 1, accuracy: 0.0001)
    }

    // MARK: - D20 fleet bridge

    func testFleetMentionCandidatesIncludeHiddenBots() {
        let hiddenBot = FleetBot(
            route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "shy")),
            displayName: "Shy Bot",
            botModeMetadata: BotModeMetadata(hidden: true))
        let visibleBot = FleetBot(
            route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")
        let candidates = FleetMentionCandidates.from(
            botsByGateway: [GatewayID(rawValue: "workstation"): [hiddenBot, visibleBot]],
            gatewayLabel: { _ in "Workstation" })
        XCTAssertEqual(candidates.count, 2, "hidden bots stay mentionable (design §3.4)")
        XCTAssertEqual(candidates.first { $0.name == "shy" }?.friendlyTitle, "Shy Bot")
    }
}
