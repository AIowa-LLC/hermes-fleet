import XCTest
import FleetCore
import FleetUI

/// RT4 regression tests for the UX/reliability polish findings that are pure
/// logic (no VM/network): P2-5 roster section building, P2-7 VoiceOver
/// semantics, P3-1 cached date formatting. Each test is a TDD regression guard:
/// RED on the pre-fix behavior, GREEN on the fix.
@MainActor
final class RT4LogicRegressionTests: XCTestCase {

    // MARK: - P2-5 all-healthy zero-bot roster → No Bots state

    private func makeGateway(_ id: String) -> FleetGateway {
        FleetGateway(id: GatewayID(rawValue: id), displayName: id, endpoint: nil)
    }

    /// RED (old): `FleetRosterView.sections` returned a section for EVERY
    /// registered gateway, so an all-healthy, zero-bot fleet rendered empty
    /// section headers and the `noBotsAnywhere` state was unreachable. GREEN
    /// (fix): healthy gateways with no bots contribute no section, so the
    /// sections array is empty → the No Bots state shows.
    func testP25AllHealthyZeroBotRosterHasNoSections() {
        let macbook = makeGateway("workstation")
        let gaming = makeGateway("render-box")
        let roster = FleetRoster(gateways: [macbook, gaming], bots: [])
        let snapshot = FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [
                macbook.id: .loaded(profileCount: 0),
                gaming.id: .loaded(profileCount: 0),
            ]
        )

        let sections = FleetRosterView.sections(from: snapshot)

        XCTAssertTrue(sections.isEmpty,
                      "P2-5: all-healthy zero-bot roster must yield NO sections (No Bots state)")
    }

    /// Healthy gateways WITH bots still produce sections (mixed fleet).
    func testP25HealthyBotsStillProduceSections() {
        let macbook = makeGateway("workstation")
        let bot = FleetBot.bot(on: macbook.id, descriptor: ProfileDescriptor(
            name: "default", path: "~/.hermes/profiles/default",
            isDefault: true, model: "hermes", provider: "nous",
            displayName: "Default", skillCount: 1, hasAvatar: false
        ))
        let roster = FleetRoster(gateways: [macbook], bots: [bot])
        let snapshot = FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [macbook.id: .loaded(profileCount: 1)]
        )

        let sections = FleetRosterView.sections(from: snapshot)

        XCTAssertEqual(sections.count, 1, "healthy gateway with bots keeps its section")
        XCTAssertNil(sections.first?.outage)
        XCTAssertEqual(sections.first?.bots.count, 1)
    }

    /// Outage sections are ALWAYS preserved, even when no bots are reported
    /// (partial-outage resilience must not regress).
    func testP25OutageSectionPreservedWhenHealthyGatewaysEmpty() {
        let arch = makeGateway("arch")
        let macbook = makeGateway("workstation")
        let roster = FleetRoster(gateways: [arch, macbook], bots: [])
        let snapshot = FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [
                arch.id: .failed(status: .offline, detail: "unreachable"),
                macbook.id: .loaded(profileCount: 0),
            ]
        )

        let sections = FleetRosterView.sections(from: snapshot)

        XCTAssertEqual(sections.count, 1, "the outage section must survive")
        XCTAssertNotNil(sections.first?.outage)
        XCTAssertEqual(sections.first?.gateway.id, arch.id)
    }

    // MARK: - P2-7 VoiceOver speaker + state semantics

    func testP27UserRowLabelAndValue() {
        let row = ConversationRow(id: "u1", kind: .user, text: "hello")
        XCTAssertEqual(row.accessibilityLabel, "User, hello")
        XCTAssertEqual(row.accessibilityValue, "")
    }

    func testP27AssistantStreamingValue() {
        let row = ConversationRow(id: "a1", kind: .assistant, text: "think", isStreaming: true)
        XCTAssertEqual(row.accessibilityLabel, "Assistant, think")
        XCTAssertEqual(row.accessibilityValue, "Streaming")
    }

    func testP27FailedValue() {
        let row = ConversationRow(id: "e1", kind: .assistant, text: "boom", isFailed: true)
        XCTAssertEqual(row.accessibilityValue, "Failed")
    }

    func testP27ToolIncludesNameAndContext() {
        let row = ConversationRow(id: "t1", kind: .tool, text: "web_search", detail: "query: apples")
        XCTAssertEqual(row.accessibilityLabel, "Tool, web_search, query: apples")
    }

    func testP27SystemStatusAndErrorSpeakers() {
        XCTAssertEqual(ConversationRow(id: "s1", kind: .status, text: "thinking").accessibilityLabel, "Status, thinking")
        XCTAssertEqual(ConversationRow(id: "s2", kind: .system, text: "background done").accessibilityLabel, "System, background done")
        XCTAssertEqual(ConversationRow(id: "s3", kind: .error, text: "failed rpc").accessibilityLabel, "Error, failed rpc")
    }

    // MARK: - P3-1 cached date formatting (parity guard)

    /// P3-1 is a pure perf refactor: `BotDetailView.dateText` now routes through
    /// the cached `FleetSessionDateText` instead of allocating a fresh
    /// `DateFormatter` per evaluated row. Behavior must be identical — this
    /// parity guard pins the output so the cache refactor cannot drift.
    func testP31CachedDateTextMatchesShortDateFormatterParity() {
        @MainActor
        func reference(_ epoch: Double) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: Date(timeIntervalSince1970: epoch))
        }

        // A handful of epochs spanning month boundaries / locales-neutral cases.
        for epoch in [0.0, 1_600_000_000, 1_700_000_000, 1_755_000_000] {
            XCTAssertEqual(FleetSessionDateText.text(epoch), reference(epoch),
                           "P3-1: cached formatter must produce identical output at \(epoch)")
        }
    }
}
