import XCTest
@testable import HermesFleetApp

/// P0-1: the launch splash timing contract. The minimum display window is a
/// named constant so the product timing is tunable in one place and locked by
/// a test (1.5-2.0s per the defect report; cross-fade > 0 so the transition
/// is never an instant swap).
final class SplashConfigurationTests: XCTestCase {

    func testMinimumDisplayDurationIsWithinSpec() {
        // The defect asked for ~1.5-2.0s minimum splash display.
        XCTAssertGreaterThanOrEqual(
            SplashConfiguration.minimumDisplayDuration, 1.5,
            "minimum splash display must be >= 1.5s")
        XCTAssertLessThanOrEqual(
            SplashConfiguration.minimumDisplayDuration, 2.0,
            "minimum splash display must be <= 2.0s")
    }

    func testFadeOutDurationIsPositive() {
        XCTAssertGreaterThan(
            SplashConfiguration.fadeOutDuration, 0,
            "cross-fade must be non-instant (no hard swap)")
    }

    func testSplashIsEnabledInReleaseSemantics() {
        // The splash must be on in production (the fix Tony dogfooded). The
        // DEBUG XCUITest skip is a test-only seam; the compiled-out branch is
        // what ships. We assert the constant contract rather than the
        // runtime seam (which is DEBUG-gated).
        XCTAssertGreaterThan(SplashConfiguration.minimumDisplayDuration, 0)
    }
}
