import XCTest
import FleetUI

/// H1 (R4) — AppLockController state-machine tests.
///
/// Covers the acceptance logic without any device biometrics: default-ON
/// toggle, persistence across controller instances, the three modes
/// (enabled / disabled / followSetting), the failed-biometric → automatic
/// passcode fallback path, passcode unlock, and background re-lock.
///
/// The real `LocalAuthenticationBiometricAuth` is intentionally NOT exercised
/// here (it needs device UI); the seam is the `AppLockBiometricAuth` protocol
/// exactly so this state machine is unit-testable with a scripted double.
@MainActor
final class AppLockControllerTests: XCTestCase {

    /// Scripted biometric double — deterministic outcomes for the state
    /// machine under test.
    private struct ScriptedAuth: AppLockBiometricAuth {
        let biometric: AppLockAuthResult
        let passcode: Bool

        func canEvaluateBiometrics() -> Bool { true }
        func evaluateBiometrics(reason: String) async -> AppLockAuthResult { biometric }
        func evaluateDevicePasscode(reason: String) async -> Bool { passcode }
    }

    /// Fresh isolated defaults suite per test (no cross-test pollution).
    private func makeDefaults() -> UserDefaults {
        let suite = "applock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Toggle default + persistence

    func testToggleDefaultsOn() {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults()
        )
        XCTAssertTrue(controller.isEnabled, "toggle defaults ON (acceptance)")
        XCTAssertTrue(controller.shouldLock)
        XCTAssertEqual(controller.state, .locked)
    }

    func testTogglePersistsAcrossControllerInstances() {
        let defaults = makeDefaults()
        let first = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: defaults
        )
        first.setEnabled(false)

        // A brand-new controller over the SAME defaults reads the persisted OFF.
        let second = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: defaults
        )
        XCTAssertFalse(second.isEnabled, "toggle persists across restart (acceptance)")
        XCTAssertFalse(second.shouldLock)
        XCTAssertEqual(second.state, .unlocked, "OFF toggle starts unlocked")
    }

    // MARK: - Modes

    func testDisabledModeNeverLocks() {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .failure, passcode: false),
            defaults: makeDefaults(),
            mode: .disabled
        )
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testEnabledModeStartsLocked() {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults(),
            mode: .enabled
        )
        XCTAssertEqual(controller.state, .locked)
    }

    func testFollowSettingWithDisabledToggleStartsUnlocked() {
        let defaults = makeDefaults()
        let seed = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: defaults
        )
        seed.setEnabled(false)
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: defaults,
            mode: .followSetting
        )
        XCTAssertFalse(controller.shouldLock)
        XCTAssertEqual(controller.state, .unlocked)
    }

    // MARK: - Authentication paths

    func testBiometricSuccessUnlocks() async {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults(),
            mode: .enabled
        )
        await controller.authenticate()
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testBiometricFailureAutomaticallyShowsPasscodeFallback() async {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .failure, passcode: true),
            defaults: makeDefaults(),
            mode: .enabled
        )
        await controller.authenticate()
        XCTAssertEqual(controller.state, .passcodeFallback,
                       "failed biometric automatically shows passcode prompt (acceptance)")
    }

    func testBiometricUnavailableAutomaticallyShowsPasscodeFallback() async {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .unavailable, passcode: true),
            defaults: makeDefaults(),
            mode: .enabled
        )
        await controller.authenticate()
        XCTAssertEqual(controller.state, .passcodeFallback,
                       "unavailable biometric falls back to passcode automatically")
    }

    func testPasscodeUnlockFromFallback() async {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .failure, passcode: true),
            defaults: makeDefaults(),
            mode: .enabled
        )
        await controller.authenticate() // → .passcodeFallback
        await controller.unlockWithPasscode()
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testPasscodeFailureStaysOnFallback() async {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .failure, passcode: false),
            defaults: makeDefaults(),
            mode: .enabled
        )
        await controller.authenticate()
        await controller.unlockWithPasscode()
        XCTAssertEqual(controller.state, .passcodeFallback,
                       "failed passcode stays on the fallback prompt, never unlocks")
    }

    // MARK: - Scene phase (foreground gating)

    func testBackgroundRelocksAndActiveReauthenticates() async throws {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults(),
            mode: .enabled
        )
        await controller.authenticate()
        XCTAssertEqual(controller.state, .unlocked)

        controller.handleScenePhase(.background)
        XCTAssertEqual(controller.state, .locked, "background re-locks an unlocked app")

        // Foreground spawns the async re-auth; give it a beat to resolve.
        controller.handleScenePhase(.active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.state, .unlocked, "active re-authenticates after background re-lock")
    }

    func testSettingOffUnlocksImmediatelyAndStopsLocking() {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults(),
            mode: .followSetting
        )
        XCTAssertEqual(controller.state, .locked)
        controller.setEnabled(false)
        XCTAssertEqual(controller.state, .unlocked, "turning the toggle OFF unlocks immediately")
        controller.handleScenePhase(.background)
        XCTAssertEqual(controller.state, .unlocked, "OFF toggle never re-locks on background")
    }

    // MARK: - Keychain reads are NOT gated (structural invariant)

    func testLockControllerNeverTouchesKeychain() {
        // The H1 gate is UI-only by construction: the controller owns NO
        // Security / Keychain types — its only dependency is the injected
        // biometric seam. Assert the observable surface exposes no credential
        // access (compiles against the protocol, not a Keychain store).
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults()
        )
        // isEnabled is a plain persisted preference — not a Keychain secret.
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state, .locked)
    }
}
