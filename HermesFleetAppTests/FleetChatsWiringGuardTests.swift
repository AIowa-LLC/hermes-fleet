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

    // MARK: - Corrective pass F1: roster + dashboard latest-session previews

    private var rosterPath: String { "Packages/FleetUI/Sources/FleetUI/FleetRosterView.swift" }
    private var dashboardPath: String { "Packages/FleetUI/Sources/FleetUI/FleetDashboardView.swift" }

    /// F1: the roster bot row renders the gateway's stored `SessionSummary`
    /// preview in BOTH the visible line and the composite VoiceOver label — QA
    /// found the raw stored string (client control markup + internal paths)
    /// still reaching users on current main.
    func testRosterBotRowRendersHumanReadablePreview() throws {
        let source = try source(rosterPath)
        XCTAssertTrue(source.contains("SessionPreviewText.humanReadable("),
                      "the roster bot row's latest-session preview must derive through SessionPreviewText")
        XCTAssertFalse(source.contains("preview: anchor.preview"),
                       "the roster must not pass the raw stored preview into the visible or VoiceOver line")
    }

    /// F1: the dashboard Active Now subtitle is a user-facing latest-session
    /// surface too — same sanitizer, same contract.
    func testDashboardActiveSubtitleRendersHumanReadablePreview() throws {
        let source = try source(dashboardPath)
        XCTAssertTrue(source.contains("SessionPreviewText.humanReadable("),
                      "the dashboard Active Now subtitle must derive through SessionPreviewText")
        XCTAssertTrue(source.contains("\\(readable)"),
                      "the subtitle must interpolate the sanitized value, not the raw stored preview")
        XCTAssertFalse(source.contains("· \\(preview)"),
                       "the dashboard subtitle must not render the raw stored preview")
    }

    // MARK: - Corrective pass F2: surface ids must ride leaves, never containers

    /// F2: a container `.accessibilityIdentifier` overrides EVERY descendant id
    /// (repo lesson) — QA found `fleet.chats.refresh.retry` at count zero while
    /// the Retry button was visibly hittable. The surface ids must NOT sit on
    /// the wrapping HStack/VStack (right after its padding); they ride leaf
    /// elements so the Retry control keeps its own id.
    func testChatsFailureSurfaceIdentifiersRideLeavesNotContainers() throws {
        let normalized = try source(chatsPath)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for containerAdornment in [
            ".padding(.vertical, FleetTheme.spacingXs) .accessibilityIdentifier(\"fleet.chats.refresh.inline\")",
            ".padding(.vertical, FleetTheme.spacingXs) .accessibilityIdentifier(\"fleet.chats.refresh.error\")",
        ] {
            XCTAssertFalse(normalized.contains(containerAdornment),
                           "the failure surface id must not sit on the wrapping container: \(containerAdornment)")
        }
        // The ids still exist (on leaves) and the Retry control keeps its own.
        for identifier in [
            "\"fleet.chats.refresh.inline\"", "\"fleet.chats.refresh.error\"",
            "\"fleet.chats.refresh.retry\"",
        ] {
            XCTAssertTrue(normalized.contains(identifier),
                          "the accessibility contract id must remain discoverable: \(identifier)")
        }
    }

    // MARK: - Corrective pass F3: Retry is a genuine 44pt tap target

    /// F3: `.frame(minHeight: 44)` alone leaves the accessibility frame at the
    /// label's intrinsic size (QA measured 34.3 × 15.7). The repo's established
    /// control pattern is the 44pt frame PLUS an explicit hit shape — otherwise
    /// the padded area is not the AX frame and the tap target is not real.
    func testChatsRetryControlsUseTheShared44PointTapTargetPattern() throws {
        let source = try source(chatsPath)
        let padded = source.components(separatedBy: ".frame(minWidth: 44, minHeight: 44)").count - 1
        XCTAssertGreaterThanOrEqual(padded, 2,
                                    "both Chats Retry controls must use the shared 44pt frame")
        XCTAssertTrue(source.contains(".contentShape(Rectangle())"),
                      "the padded area must be the hit shape, or the AX frame stays at label size")
        XCTAssertFalse(source.contains(".frame(minHeight: 44)"),
                       "a bare minHeight frame does not expand the accessibility frame")
    }

    // MARK: - Corrective pass F4/F5: view call sites use the policies

    /// F4: the empty state must be the filter-aware policy, not the old
    /// query-only ternary that claimed "no data" behind a gateway filter.
    func testChatsEmptyStateUsesTheFilterAwarePolicy() throws {
        let source = try source(chatsPath)
        XCTAssertTrue(source.contains("FleetChatsPresentation.emptyState("),
                      "the empty state must be decided by the filter-aware policy")
        XCTAssertFalse(source.contains("\"Your next idea starts here\""),
                       "the first-run copy must come from the policy, never hard-coded in the view")
    }

    /// F5: the prominent copy must be told whether the refresh is still
    /// running, so it does not claim a settled result it cannot know yet.
    func testChatsProminentFailurePassesTheLiveRefreshState() throws {
        let source = try source(chatsPath)
        XCTAssertTrue(source.contains("isRefreshing: !environment.loadingRoutes.isEmpty"),
                      "the settled-claim copy must be gated on the live refresh state")
    }
}