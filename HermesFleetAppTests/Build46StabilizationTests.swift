import XCTest
import FleetCore
@testable import FleetUI

@MainActor
final class Build46StabilizationTests: XCTestCase {
    func testPathSafeAttachmentNameRemovesTraversalSeparatorsAndControls() {
        XCTAssertEqual(
            AttachmentStagingRules.pathSafeBasename("../private\\notes\u{0000}.md"),
            "private_notes_.md")
    }

    func testReasoningPreferenceDefaultsCollapsedAndPersistsExpandedChoice() {
        let suiteName = "Build46StabilizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ReasoningPresentationPreference.current(from: defaults), .collapsed)
        defaults.set(ReasoningPresentationPreference.expanded.rawValue,
                     forKey: ReasoningPresentationPreference.storageKey)
        XCTAssertEqual(ReasoningPresentationPreference.current(from: defaults), .expanded)
    }

    func testReasoningDefaultsCollapsedAndManualOverrideWins() {
        var state = ReasoningExpansionState(default: .collapsed)
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.hasUserOverride)

        state.toggle()
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.hasUserOverride)

        state.applyDefault(.collapsed)
        XCTAssertTrue(state.isExpanded)
    }

    func testReasoningExpandedPreferenceAppliesOnlyBeforeOverride() {
        var state = ReasoningExpansionState(default: .collapsed)
        state.applyDefault(.expanded)
        XCTAssertTrue(state.isExpanded)

        state.toggle()
        XCTAssertFalse(state.isExpanded)
        state.applyDefault(.expanded)
        XCTAssertFalse(state.isExpanded)
    }

    func testReasoningUserOverrideWinsOverStreamingOrDefaultRefresh() {
        var state = ReasoningExpansionState(default: .collapsed)
        state.toggle()
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.hasUserOverride)

        state.applyDefault(.collapsed)
        XCTAssertTrue(state.isExpanded)
    }
}
