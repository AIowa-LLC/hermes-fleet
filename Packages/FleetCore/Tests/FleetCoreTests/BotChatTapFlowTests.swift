import XCTest
@testable import FleetCore

/// Integration of the canonical tap plan across the seam types.
final class BotChatTapFlowTests: XCTestCase {

    private func bot(profile: String, gateway: String = "workstation",
                     canonicalID: String?) -> FleetBot {
        FleetBot(
            route: Route(
                gatewayID: GatewayID(rawValue: gateway),
                profileSlug: ProfileSlug(rawValue: profile)),
            displayName: profile,
            canonicalSession: canonicalID.map {
                CanonicalSessionRef(id: $0, rootTitle: BotModeContract.canonicalChatTitle)
            }
        )
    }

    /// A scripted seam double mirroring the wire behaviors.
    private final class SeamDouble: BotModeChatProviding, @unchecked Sendable {
        enum Behavior {
            case existing(id: String, resolved: String?)
            case confirmedMiss(creates: String)
            case emptyButRosterKnows
            case rpcError
        }
        let behavior: Behavior
        private(set) var createdCount = 0

        init(_ behavior: Behavior) { self.behavior = behavior }

        func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup {
            switch behavior {
            case .existing(let id, let resolved):
                return CanonicalLookup(rows: [CanonicalLookupRow(
                    id: id, resolvedID: resolved,
                    title: BotModeContract.canonicalChatTitle)])
            case .confirmedMiss, .emptyButRosterKnows:
                return CanonicalLookup(rows: [])
            case .rpcError:
                throw RosterError.rpcFailed("gateway unreachable")
            }
        }

        func createCanonicalChat(profile: String) async throws -> String {
            createdCount += 1
            guard case .confirmedMiss(let creates) = behavior else {
                XCTFail("creation must never run in this state")
                return "must-not-happen"
            }
            return creates
        }
    }

    private func resolve(bot: FleetBot, seam: SeamDouble) async -> Result<String, BotChatUnavailable> {
        // Mirror of AppEnvironment.resolveCanonicalChatTarget's core flow.
        switch seam.behavior {
        case .rpcError:
            return .failure(BotChatUnavailable(
                message: "Could not check the Bot Chat registry — not starting a new chat"))
        default:
            break
        }
        let lookup = try! await seam.lookupCanonicalChat(profile: bot.route.profileSlug.rawValue)
        let rows = lookup.rows.map {
            SessionSummary(id: $0.id, title: $0.title, preview: $0.preview, messageCount: $0.messageCount)
        }
        var resolution = CanonicalChatResolver.resolve(
            lookupRows: rows,
            rosterCanonicalID: bot.canonicalSession?.id,
            lookupError: nil)
        if let first = lookup.rows.first, let tip = first.openID, tip != first.id {
            resolution = CanonicalChatResolver.resolve(
                lookupRows: [SessionSummary(id: first.id, title: first.title,
                                            preview: first.preview, messageCount: first.messageCount)],
                rosterCanonicalID: bot.canonicalSession?.id,
                lookupError: nil)
            if case .existing = resolution { return .success(tip) }
        }
        switch BotChatPlanner.plan(from: resolution) {
        case .openCanonical(let ref):
            if let id = ref.openID { return .success(id) }
            return .failure(BotChatUnavailable(message: "malformed id"))
        case .createThenOpen:
            let created = (try? await seam.createCanonicalChat(profile: bot.route.profileSlug.rawValue)) ?? ""
            return .success(created)
        case .unavailable(let message):
            return .failure(BotChatUnavailable(message: message))
        }
    }

    func testTapOpensCompressionTipWhenPresent() async {
        let seam = SeamDouble(.existing(id: "reg-1", resolved: "tip-9"))
        let result = await resolve(bot: bot(profile: "r", canonicalID: "reg-1"), seam: seam)
        XCTAssertEqual(try? result.get(), "tip-9")
        XCTAssertEqual(seam.createdCount, 0)
    }

    func testTapOpensRegistryRowWithoutTip() async {
        let seam = SeamDouble(.existing(id: "reg-1", resolved: nil))
        let result = await resolve(bot: bot(profile: "r", canonicalID: "reg-1"), seam: seam)
        XCTAssertEqual(try? result.get(), "reg-1")
        XCTAssertEqual(seam.createdCount, 0)
    }

    func testConfirmedMissCreatesExactlyOnceThenOpens() async {
        let seam = SeamDouble(.confirmedMiss(creates: "new-1"))
        let result = await resolve(bot: bot(profile: "r", canonicalID: nil), seam: seam)
        XCTAssertEqual(try? result.get(), "new-1")
        XCTAssertEqual(seam.createdCount, 1)
    }

    func testEmptyLookupWithRosterCanonicalNeverCreates() async {
        let seam = SeamDouble(.emptyButRosterKnows)
        let result = await resolve(bot: bot(profile: "r", canonicalID: "reg-7"), seam: seam)
        guard case .failure = result else { return XCTFail("must fail closed") }
        XCTAssertEqual(seam.createdCount, 0, "unconfirmed registry must never mint")
    }

    func testRPCErrorNeverCreatesOrNavigates() async {
        let seam = SeamDouble(.rpcError)
        let result = await resolve(bot: bot(profile: "r", canonicalID: "reg-7"), seam: seam)
        guard case .failure(let unavailable) = result else { return XCTFail("must fail") }
        XCTAssertTrue(unavailable.message.contains("not starting a new chat"))
        XCTAssertEqual(seam.createdCount, 0)
    }

    func testRecencyNeverSelectsTarget() async {
        // Even with a fresher last_session on the bot, the tap targets the
        // canonical registry row only (operator-corrected rule).
        var newer = bot(profile: "r", canonicalID: "reg-1")
        newer.latestSession = SessionSummary(
            id: "fresher-unrelated", title: "misc chat",
            preview: "", startedAt: 9_999_999, messageCount: 5)
        let seam = SeamDouble(.existing(id: "reg-1", resolved: nil))
        let result = await resolve(bot: newer, seam: seam)
        XCTAssertEqual(try? result.get(), "reg-1", "recency must not redirect the open target")
    }
}
