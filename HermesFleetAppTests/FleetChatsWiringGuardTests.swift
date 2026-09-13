import XCTest
import FleetUI
import FleetCore

/// Dogfood findings 1–3 — SOURCE-LEVEL wiring guards.
///
/// The transformed behavior is unit-tested directly (`SessionPreviewTextTests`,
/// `FleetChatsPresentationTests`); what those cannot prove is that the three
/// CURRENT-MAIN render sites actually route through it, and that the Chats
/// failure surface uses the scoped policy and the token-based bottom reserve.
/// A UI geometry assertion was evaluated and rejected: the scripted Chats list
/// does not overflow the viewport deterministically, so a "last row clears the
/// floating tab bar" frame comparison would be non-discriminating (and the
/// iOS 26 floating-bar frame is itself unstable across runs). These guards
/// pin the wiring at the source level instead.
final class FleetChatsWiringGuardTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HermesFleetAppTests/
        .deletingLastPathComponent() // repo root

    private func source(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var chatsPath: String { "Packages/FleetUI/Sources/FleetUI/FleetDestinations.swift" }
    private var botDetailPath: String { "Packages/FleetUI/Sources/FleetUI/BotDetailView.swift" }
    private var projectsPath: String { "Packages/FleetUI/Sources/FleetUI/ProjectsView.swift" }

    // MARK: - Finding 2: every session row renders the human-readable derivation

    func testChatsSessionRowsRenderHumanReadablePreviews() throws {
        let source = try source(chatsPath)
        XCTAssertTrue(source.contains("SessionPreviewText.humanReadable("),
                      "Chats must derive its preview line through SessionPreviewText")
        XCTAssertFalse(source.contains("Text(entry.session.preview)"),
                       "Chats must never render the raw stored preview")
    }

    func testBotDetailSessionRowsRenderHumanReadablePreviews() throws {
        let source = try source(botDetailPath)
        XCTAssertTrue(source.contains("SessionPreviewText.humanReadable("),
                      "Bot detail session rows must derive their preview line")
        XCTAssertFalse(source.contains("Text(session.preview)"),
                       "Bot detail must never render the raw stored preview")
    }

    func testProjectsSessionRowsRenderHumanReadablePreviews() throws {
        let source = try source(projectsPath)
        XCTAssertTrue(source.contains("SessionPreviewText.humanReadable("),
                      "Projects session rows must derive their preview line")
        XCTAssertFalse(source.contains("+ session.preview"),
                       "Projects must never append the raw stored preview")
    }

    /// Presentation-only: the derivation is NOT part of the model. If it were
    /// folded into `SessionSummary` the protocol payload would be coupled to a
    /// display concern.
    func testDerivationIsNotCouplingTheModel() throws {
        let model = try source("Packages/FleetCore/Sources/FleetCore/SessionSummary.swift")
        XCTAssertFalse(model.contains("SessionPreviewText"),
                       "SessionSummary must stay a pure wire model (no display coupling)")
    }

    // MARK: - Finding 1: the failure surface uses the scoped policy

    func testChatsFailureSurfaceUsesRefreshFailurePolicy() throws {
        let source = try source(chatsPath)
        XCTAssertTrue(source.contains("FleetChatsPresentation.refreshFailureSurface("),
                      "the Chats failure surface must be decided by the policy")
        XCTAssertTrue(source.contains("FleetChatsPresentation.currentFailureRoutes("),
                      "reported failures must be scoped to routes Retry can re-read")
        XCTAssertTrue(source.contains("FleetChatsPresentation.prominentFailureDetail("),
                      "the empty/error copy must be truthful about partial vs total")
    }

    func testChatsFailureSurfacesAreIdentifiableForTheAccessibilityTree() throws {
        let source = try source(chatsPath)
        XCTAssertTrue(source.contains("fleet.chats.refresh.inline"),
                      "the compact inline failure needs a stable accessibility id")
        XCTAssertTrue(source.contains("fleet.chats.refresh.retry"),
                      "the retry affordance needs a stable accessibility id")
    }

    // MARK: - FOS theme environment pattern (no bespoke static color tokens)

    func testChatsUsesTheThemeEnvironmentForSurfaces() throws {
        let source = try source(chatsPath)
        for staticToken in [
            "FleetTheme.textSecondary", "FleetTheme.textPrimary",
            "FleetTheme.accent", "FleetTheme.background", "FleetTheme.highlight",
        ] {
            XCTAssertFalse(source.contains(staticToken),
                           "FOS-6 pattern: \(staticToken) must come from the theme environment")
        }
        XCTAssertTrue(source.contains("theme.textSecondary"),
                      "Chats must keep rendering through the injected fleet theme")
    }

    // MARK: - Finding 3: bottom reserve is a safe-area inset with a token

    func testChatsReservesBottomSpaceWithSafeAreaInsetAndToken() throws {
        let source = try source(chatsPath)
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom"),
                      "the Chats list must reserve bottom space with a safe-area API")
        XCTAssertTrue(source.contains("FleetChatsListLayout.bottomBreathingRoom"),
                      "the reserve must be a named design-token value, not a magic number")
        XCTAssertTrue(source.contains("Color.clear"),
                      "the reserve is an invisible spacer (no visual change)")
    }
}