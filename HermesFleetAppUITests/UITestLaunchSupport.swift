import XCTest

/// Shared launch guard for deterministic UI suites.
///
/// Hosted runners occasionally report a launch-timeout while the app is still
/// booting. Only the readiness probe is retried, exactly once; assertion
/// failures after the app is ready remain real test failures.
enum UITestLaunchSupport {
    @discardableResult
    static func launch(
        _ app: XCUIApplication,
        ready: XCUIElement,
        timeout: TimeInterval = 15
    ) -> Bool {
        app.launch()
        if ready.waitForExistence(timeout: timeout) {
            return true
        }

        app.terminate()
        app.launch()
        return ready.waitForExistence(timeout: timeout)
    }
}
