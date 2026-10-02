import XCTest
import FleetUI

@MainActor
final class AppLockAuthenticationLifecycleTests: XCTestCase {
    private actor GatedAuthentication: AppLockBiometricAuth {
        private(set) var biometricCalls = 0
        private(set) var passcodeCalls = 0
        private var biometricResults: [Int: AppLockAuthResult] = [:]
        private var passcodeResult: Bool?

        nonisolated func canEvaluateBiometrics() -> Bool { true }

        func evaluateBiometrics(reason: String) async -> AppLockAuthResult {
            biometricCalls += 1
            let attempt = biometricCalls
            while biometricResults[attempt] == nil {
                if Task.isCancelled { return .failure }
                await Task.yield()
            }
            return biometricResults[attempt]!
        }

        func evaluateDevicePasscode(reason: String) async -> Bool {
            passcodeCalls += 1
            while passcodeResult == nil {
                if Task.isCancelled { return false }
                await Task.yield()
            }
            return passcodeResult!
        }

        func finishBiometrics(_ result: AppLockAuthResult, attempt: Int = 1) {
            biometricResults[attempt] = result
        }
        func finishPasscode(_ result: Bool) { passcodeResult = result }
    }

    private func makeController(_ auth: GatedAuthentication) -> AppLockController {
        let defaults = UserDefaults(suiteName: "auth-lifecycle-\(UUID().uuidString)")!
        return AppLockController(auth: auth, defaults: defaults, mode: .followSetting)
    }

    private func waitForBiometrics(_ auth: GatedAuthentication, calls: Int = 1) async {
        for _ in 0..<1000 {
            if await auth.biometricCalls >= calls { return }
            await Task.yield()
        }
        XCTFail("the controlled biometric attempt did not start")
    }

    private func waitForPasscode(_ auth: GatedAuthentication) async {
        for _ in 0..<1000 {
            if await auth.passcodeCalls > 0 { return }
            await Task.yield()
        }
        XCTFail("the controlled passcode attempt did not start")
    }

    func testStaleBiometricFailureCannotRelockAfterSettingOff() async {
        let auth = GatedAuthentication()
        let controller = makeController(auth)
        let attempt = Task { await controller.authenticate() }
        await waitForBiometrics(auth)
        XCTAssertEqual(controller.state, .authenticating)
        controller.setEnabled(false)
        await auth.finishBiometrics(.failure)
        await attempt.value
        XCTAssertFalse(controller.shouldLock)
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testStalePasscodeFailureCannotRelockAfterSettingOff() async {
        let auth = GatedAuthentication()
        let controller = makeController(auth)
        let attempt = Task { await controller.unlockWithPasscode() }
        await waitForPasscode(auth)
        XCTAssertEqual(controller.state, .authenticating)
        controller.setEnabled(false)
        await auth.finishPasscode(false)
        await attempt.value
        XCTAssertFalse(controller.shouldLock)
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testAuthenticationStartedBeforeBackgroundCannotUnlockNewLifecycle() async {
        let auth = GatedAuthentication()
        let controller = makeController(auth)
        let attempt = Task { await controller.authenticate() }
        await waitForBiometrics(auth)
        XCTAssertEqual(controller.state, .authenticating)
        controller.handleScenePhase(.background)
        await auth.finishBiometrics(.success)
        await attempt.value
        XCTAssertTrue(controller.shouldLock)
        XCTAssertTrue(controller.isLocked)
    }

    func testReturnToActiveWaitsForOldAttemptThenAuthenticatesOnce() async {
        let auth = GatedAuthentication()
        let controller = makeController(auth)
        let attempt = Task { await controller.authenticate() }
        await waitForBiometrics(auth)
        controller.handleScenePhase(.background)
        controller.handleScenePhase(.active)
        controller.handleScenePhase(.active)
        for _ in 0..<20 { await Task.yield() }
        let pendingCalls = await auth.biometricCalls
        XCTAssertEqual(pendingCalls, 1, "an old prompt must finish before starting another")
        await auth.finishBiometrics(.success)
        await attempt.value
        await waitForBiometrics(auth, calls: 2)
        XCTAssertTrue(controller.isLocked, "the old result cannot unlock the new lifecycle")
        await auth.finishBiometrics(.success, attempt: 2)
        for _ in 0..<1000 {
            if controller.state == .unlocked { break }
            await Task.yield()
        }
        let completedCalls = await auth.biometricCalls
        XCTAssertEqual(completedCalls, 2)
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testInactiveAuthenticationSheetPreservesValidAttemptWithoutPrivacyFlash() async {
        let auth = GatedAuthentication()
        let controller = makeController(auth)
        let attempt = Task { await controller.authenticate() }
        await waitForBiometrics(auth)
        controller.handleScenePhase(.inactive)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
        await auth.finishBiometrics(.success)
        await attempt.value
        XCTAssertEqual(controller.state, .unlocked)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
        let calls = await auth.biometricCalls
        XCTAssertEqual(calls, 1)
    }
}
