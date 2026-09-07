import XCTest
@testable import HermesFleetApp

/// Launch-splash timing contract. The minimum display window is a named
/// constant so product timing is tunable in one place and bounded by tests.
final class SplashConfigurationTests: XCTestCase {

    func testMinimumDisplayDurationIsWithinSpec() {
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
        // Production builds compile the always-on branch. The DEBUG XCUITest
        // skip is a test-only seam, so this test pins the nonzero timing
        // contract shared by production behavior.
        XCTAssertGreaterThan(SplashConfiguration.minimumDisplayDuration, 0)
    }
}
