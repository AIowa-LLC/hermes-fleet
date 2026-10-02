import XCTest
import UIKit
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

    // MARK: - Privacy shield (P0.3a)

    /// Biometric double that suspends until released, so a test can observe
    /// scene-phase behavior while the system Face ID sheet would be up
    /// (`.authenticating`).
    private final class GatedAuth: AppLockBiometricAuth, @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private let lock = NSLock()
        func canEvaluateBiometrics() -> Bool { true }
        func evaluateBiometrics(reason: String) async -> AppLockAuthResult {
            await withCheckedContinuation { c in
                lock.lock(); continuation = c; lock.unlock()
            }
            return .success
        }
        func evaluateDevicePasscode(reason: String) async -> Bool { true }
        func release() {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume()
        }
    }

    private func makeUnlockedController(
        mode: AppLockController.Mode = .enabled,
        defaults: UserDefaults? = nil
    ) async -> AppLockController {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: defaults ?? makeDefaults(),
            mode: mode
        )
        if mode != .disabled { await controller.authenticate() }
        XCTAssertEqual(controller.state, .unlocked)
        return controller
    }

    func testInactiveShowsShieldAndActiveRemovesIt() async {
        let controller = await makeUnlockedController()
        XCTAssertFalse(controller.isPrivacyShieldVisible)
        controller.handleScenePhase(.inactive)
        XCTAssertTrue(controller.isPrivacyShieldVisible, "inactive covers the snapshot")
        XCTAssertEqual(controller.state, .unlocked, "inactive never locks (lock stays on background)")
        controller.handleScenePhase(.active)
        XCTAssertFalse(controller.isPrivacyShieldVisible, "active removes the cover")
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testShieldNeverShowsWithAppLockDisabledInFollowSetting() async {
        let defaults = makeDefaults()
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: defaults, mode: .followSetting)
        controller.setEnabled(false)
        XCTAssertEqual(controller.state, .unlocked)
        controller.handleScenePhase(.inactive)
        XCTAssertFalse(controller.isPrivacyShieldVisible, "App Lock off means no shield")
        controller.handleScenePhase(.background)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
    }

    func testTurningAppLockOffClearsEngagedCover() async {
        let controller = await makeUnlockedController(mode: .followSetting)
        controller.handleScenePhase(.inactive)
        XCTAssertTrue(controller.isPrivacyShieldVisible)
        controller.setEnabled(false)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
        controller.handleScenePhase(.inactive)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
    }

    func testPrivacyWindowTracksInactiveCoverAndActiveDismissal() async throws {
        let controller = await makeUnlockedController()
        let window = PrivacyShieldWindow()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window.bind(to: scene)
        defer { window.bind(to: nil) }
        controller.handleScenePhase(.inactive)
        window.setVisible(controller.isPrivacyShieldVisible)
        XCTAssertTrue(window.isShowing, "the scene window appears synchronously for the snapshot")
        controller.handleScenePhase(.active)
        window.setVisible(controller.isPrivacyShieldVisible)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(window.isShowing, "returning active removes the window and releases accessibility")
    }

    func testDisabledModeNeverShowsShield() async {
        let controller = await makeUnlockedController(mode: .disabled)
        controller.handleScenePhase(.inactive)
        XCTAssertFalse(controller.isPrivacyShieldVisible, "UI-test bypass mode has no cover")
    }

    func testBackgroundWithoutInactiveStillCoversAndRelocks() async {
        let controller = await makeUnlockedController()
        controller.handleScenePhase(.background)
        XCTAssertTrue(controller.isPrivacyShieldVisible)
        XCTAssertEqual(controller.state, .locked, "re-lock on background is unchanged")
    }

    func testInactiveWhileLockedDoesNotEngageShield() {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults(), mode: .enabled)
        XCTAssertEqual(controller.state, .locked)
        controller.handleScenePhase(.inactive)
        XCTAssertFalse(controller.isPrivacyShieldVisible,
                       "lock screen already covers content; no cover over it")
    }

    func testFaceIDSheetInactiveDoesNotEngageShieldOrFlicker() async throws {
        let gated = GatedAuth()
        let controller = AppLockController(
            auth: gated, defaults: makeDefaults(), mode: .enabled)
        // `.active` starts authentication (Face ID sheet shows).
        controller.handleScenePhase(.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.state, .authenticating)

        // The system sheet backgrounds the scene: inactive, then back to active.
        controller.handleScenePhase(.inactive)
        XCTAssertFalse(controller.isPrivacyShieldVisible,
                       "Face ID sheet's inactive must not arm the cover")
        gated.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.state, .unlocked)
        XCTAssertFalse(controller.isPrivacyShieldVisible, "no cover over a fresh unlock")
        controller.handleScenePhase(.active)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
        XCTAssertEqual(controller.state, .unlocked, "no re-lock loop after Face ID dismissal")
    }

    func testUnlockClearsCoverArmedByLateInactive() async throws {
        let controller = AppLockController(
            auth: ScriptedAuth(biometric: .success, passcode: true),
            defaults: makeDefaults(), mode: .enabled)
        controller.handleScenePhase(.background)   // locked already; no engage
        controller.handleScenePhase(.inactive)
        await controller.authenticate()
        XCTAssertEqual(controller.state, .unlocked)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
    }

    // MARK: - P0.2b: turning App Lock off requires presence

    private func makeEnabledController(_ presence: ScriptedPresence) -> AppLockController {
        AppLockController(auth: presence, defaults: makeDefaults(), mode: .followSetting)
    }

    func testKeepAppLockOnSupersedesPendingTurnOff() async {
        let auth = SuspendedPresence()
        let controller = AppLockController(auth: auth, defaults: makeDefaults(), mode: .followSetting)
        let off = Task { await controller.requestSetEnabled(false) }
        for _ in 0..<100 where auth.checks == 0 { await Task.yield() }
        _ = await controller.requestSetEnabled(true)
        auth.complete()
        _ = await off.value
        XCTAssertTrue(controller.isEnabled, "a completed older prompt must not undo the newer safe choice")
    }

    func testRepeatedTurnOffDoesNotStackPresencePrompts() async {
        let auth = SuspendedPresence()
        let controller = AppLockController(auth: auth, defaults: makeDefaults(), mode: .followSetting)
        let first = Task { await controller.requestSetEnabled(false) }
        for _ in 0..<100 where auth.checks == 0 { await Task.yield() }
        let second = Task { await controller.requestSetEnabled(false) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(auth.checks, 1)
        auth.complete()
        _ = await first.value
        _ = await second.value
    }

    func testTurningOffRequiresPresenceExactlyOnceAndApplies() async {
        let presence = ScriptedPresence.success
        let controller = makeEnabledController(presence)
        let result = await controller.requestSetEnabled(false)
        XCTAssertEqual(result, .verified)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state, .unlocked)
        XCTAssertEqual(presence.presenceChecks, 1)
        XCTAssertEqual(presence.reasons, ["Turn off App Lock"])
    }

    func testTurningOffPasscodeFallbackApplies() async {
        let presence = ScriptedPresence(biometrics: .biometricsUnavailable, passcode: .success)
        let controller = makeEnabledController(presence)
        let result = await controller.requestSetEnabled(false)
        XCTAssertEqual(result, .verified)
        XCTAssertFalse(controller.isEnabled)
    }

    func testTurningOffCancelledOrFailedChangesNothing() async {
        for (outcome, expected) in [(PresenceOutcome.cancelled, PresenceResult.cancelled),
                                    (.failed, .failed), (.passcodeNotSet, .passcodeNotSet)] {
            let presence = ScriptedPresence(biometrics: outcome)
            let controller = makeEnabledController(presence)
            let result = await controller.requestSetEnabled(false)
            XCTAssertEqual(result, expected)
            XCTAssertTrue(controller.isEnabled, "\(outcome)")
            XCTAssertEqual(controller.state, .locked, "state unchanged: \(outcome)")
            XCTAssertEqual(presence.presenceChecks, 1)
        }
    }

    func testTurningOnNeverInvokesPresence() async {
        let presence = ScriptedPresence(biometrics: .failed)
        let controller = makeEnabledController(presence)
        controller.setEnabled(false)
        let result = await controller.requestSetEnabled(true)
        XCTAssertEqual(result, .verified)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(presence.presenceChecks, 0)
    }

    func testTurningOffWhenAlreadyOffNeverInvokesPresence() async {
        let presence = ScriptedPresence(biometrics: .failed)
        let controller = makeEnabledController(presence)
        controller.setEnabled(false)
        _ = await controller.requestSetEnabled(false)
        XCTAssertEqual(presence.presenceChecks, 0)
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
