import Foundation
import Observation
import SwiftUI
import FleetCore

// MARK: - Biometric authentication seam (H1 app lock)

/// Result of a single biometric (Face ID / Touch ID) evaluation.
public enum AppLockAuthResult: Equatable, Sendable {
    /// Biometrics verified — the user is authenticated.
    case success
    /// Biometrics were presented but did not match / the user cancelled.
    case failure
    /// No biometrics are enrolled/available on this device (or the policy
    /// cannot evaluate) — the automatic passcode fallback must be shown.
    case unavailable
}

/// The seam the lock screen uses to talk to the platform's authentication.
///
/// Lives in FleetUI as a protocol (M0: SwiftUI depends only on FleetCore +
/// system frameworks). The concrete implementations live in the app target's
/// composition root:
/// - `LocalAuthenticationBiometricAuth` — the real LAContext provider
///   (production; `.deviceOwnerAuthentication` gives the automatic device
///   passcode fallback).
/// - DEBUG test-automation providers driven by `HERMES_FLEET_APP_LOCK` /
///   `HERMES_FLEET_LOCK_BIOMETRIC` launch environment.
public protocol AppLockBiometricAuth: PresenceEvaluating {
    /// Whether biometrics are enrolled/available on this device.
    func canEvaluateBiometrics() -> Bool
    /// Attempt biometric verification. `.failure` / `.unavailable` → the
    /// controller automatically transitions to the passcode fallback.
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult
    /// Attempt device passcode verification (system UI). Returns true only
    /// on success; false on cancel/failure/absent passcode.
    func evaluateDevicePasscode(reason: String) async -> Bool
}

// MARK: - User-presence gate (P0.2b)

extension AppLockBiometricAuth {
    /// Default platform evaluation built from the legacy two-method seam so
    /// existing providers keep working. The production
    /// `LocalAuthenticationBiometricAuth` overrides this with real `LAError`
    /// mapping (cancel / lockout / no passcode).
    public func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
        switch policy {
        case .biometricsOnly:
            switch await evaluateBiometrics(reason: reason) {
            case .success: return .success
            case .failure: return .failed
            case .unavailable: return .biometricsUnavailable
            }
        case .deviceOwner:
            return await evaluateDevicePasscode(reason: reason) ? .success : .failed
        }
    }

    /// The single user-presence check for privilege-expanding actions:
    /// biometrics first, device passcode when biometrics cannot run. Fails
    /// closed; see `UserPresenceGate`.
    public func verifyPresence(_ action: PresenceAction) async -> PresenceResult {
        await UserPresenceGate(evaluator: self).verify(action)
    }
}

// MARK: - AppLockController

/// Observable application-lock state machine (H1 / R4).
///
/// Gates the fleet UI at app foreground: when enabled and not yet
/// authenticated this session, the lock screen overlay is shown BEFORE any
/// roster/conversation content renders. Only the UI is gated — Keychain
/// reads (WhenUnlockedThisDeviceOnly) are deliberately NOT wrapped in another
/// auth prompt (mission H1 scope).
///
/// Three lock modes:
/// - `.enabled` — always lock (UI-test automation forces this on).
/// - `.disabled` — never lock (existing UI suites bypass the gate).
/// - `.followSetting` — lock iff `isEnabled` (the persisted in-app toggle,
///   default ON). Production default.
///
/// Scene phase: `.background` re-locks an unlocked app; `.active` triggers
/// authentication when locked. A failed/unavailable biometric evaluation
/// automatically shows the passcode fallback (`.passcodeFallback` state) —
/// the failed-biometric acceptance path.
///
/// Privacy shield (P0.3a): when App Lock is enabled, `.inactive` / `.background`
/// on an UNLOCKED app engages an opaque cover (`isPrivacyShieldVisible`) so the
/// app-switcher snapshot never captures conversation content. The shield only
/// engages from `.unlocked`: while the lock screen or a Face ID / passcode
/// system sheet is up (`.locked` / `.authenticating` / `.passcodeFallback`)
/// content is already gated, and the system sheet's own `.inactive` must not
/// arm a cover that would flash over the unlock. `.active` (or a successful
/// unlock) always disengages it. Lock semantics are unchanged.
@MainActor
@Observable
public final class AppLockController {

    public enum LockState: Equatable, Sendable {
        case unlocked
        case locked
        case authenticating
        case passcodeFallback
    }

    public enum Mode: Equatable, Sendable {
        case enabled
        case disabled
        case followSetting
    }

    // MARK: Observable state

    /// Current lock state. The view renders the overlay unless `.unlocked`.
    /// Default `.locked` — the app must start gated when the lock is enabled.
    public private(set) var state: LockState = .locked

    /// The persisted in-app setting (default ON). `true` → the app locks at
    /// foreground in `.followSetting` mode. Persisted via `UserDefaults`
    /// (non-secret preference — deliberately NOT Keychain).
    public private(set) var isEnabled: Bool

    /// Effective gating decision for the current mode + setting.
    public var shouldLock: Bool {
        switch mode {
        case .enabled: return true
        case .disabled: return false
        case .followSetting: return isEnabled
        }
    }

    public var isLocked: Bool { state != .unlocked }

    /// Whether the opaque privacy cover should currently be on screen.
    /// `.disabled` mode (deterministic UI-test bypass) never shows it.
    public var isPrivacyShieldVisible: Bool {
        privacyCover.isEngaged && shouldLock
    }

    // MARK: Private

    private let auth: any AppLockBiometricAuth
    private let defaults: UserDefaults
    private let mode: Mode
    private let defaultsKey: String
    private var settingIntent = 0
    public private(set) var isVerifyingSetting = false
    private var hasAuthenticatedThisSession = false
    /// Set on `.inactive`/`.background` from `.unlocked`; cleared on `.active`,
    /// on successful unlock, and when the setting is turned off.
    private var privacyCover = PrivacyShieldPolicy()

    public init(
        auth: any AppLockBiometricAuth,
        defaults: UserDefaults = .standard,
        mode: Mode = .followSetting,
        defaultsKey: String = AppLockController.defaultsKey
    ) {
        self.auth = auth
        self.defaults = defaults
        self.mode = mode
        self.defaultsKey = defaultsKey
        if defaults.object(forKey: defaultsKey) == nil {
            // Toggle defaults ON (acceptance: default ON, persisted).
            self.isEnabled = true
            defaults.set(true, forKey: defaultsKey)
        } else {
            self.isEnabled = defaults.bool(forKey: defaultsKey)
        }
        self.state = (mode == .disabled || (mode == .followSetting && !isEnabled))
            ? .unlocked
            : .locked
    }

    // MARK: Setting

    /// Update the persisted in-app toggle WITHOUT a presence check. User-facing
    /// callers turning App Lock off must use `requestSetEnabled(_:)`. Turning it OFF unlocks immediately
    /// (and stops re-locking); turning it ON locks the next time the app is
    /// foregrounded while locked.
    public func setEnabled(_ enabled: Bool) {
        settingIntent += 1
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: defaultsKey)
        if enabled {
            if state == .unlocked, shouldLock {
                state = .locked
            }
        } else {
            privacyCover.reset()
            state = .unlocked
            hasAuthenticatedThisSession = false
        }
    }

    /// P0.2b — the Settings entry point. Turning App Lock ON needs no check;
    /// turning it OFF requires a fresh user-presence check and changes nothing
    /// unless it is verified. Returns `.verified` when the change was applied
    /// (or was already in effect).
    public func requestSetEnabled(_ enabled: Bool) async -> PresenceResult {
        if enabled {
            // Even an already-on safe choice invalidates an older off prompt.
            setEnabled(true)
            return .verified
        }
        guard isEnabled else { return .verified }
        guard !isVerifyingSetting else { return .cancelled }
        isVerifyingSetting = true
        defer { isVerifyingSetting = false }
        let intent = settingIntent
        let result = await auth.verifyPresence(.turnOffAppLock)
        guard settingIntent == intent else { return .cancelled }
        guard result == .verified else { return result }
        setEnabled(false)
        return .verified
    }

    // MARK: Scene phase

    /// Scene-phase entry point (called by the app root). `.active` on a
    /// locked-but-not-yet-authenticated app triggers authentication;
    /// `.background` re-locks an unlocked app (foreground-gating).
    public func handleScenePhase(_ phase: ScenePhase) {
        privacyCover.handle(phase, contentUnlocked: state == .unlocked, enabled: shouldLock)
        switch phase {
        case .active:
            privacyCover.reset()
            if shouldLock, state == .locked {
                Task { await authenticate() }
            }
        case .inactive:
            // App-switcher snapshot protection. Only from `.unlocked`: the
            // lock screen / Face ID sheet already cover content, and their
            // `.inactive` must not arm a cover (no flicker loop).
            break
        case .background:
            // Covers a `.background` that arrives without a prior `.inactive`.
            // Evaluated BEFORE the re-lock below so it sees `.unlocked`.
            if shouldLock, state == .unlocked {
                state = .locked
                // Foreground must re-authenticate after a background re-lock —
                // clear the session flag so `.active` triggers a fresh prompt.
                hasAuthenticatedThisSession = false
            }
        @unknown default:
            break
        }
    }

    // MARK: Authentication

    /// Called at cold launch (root `.task`). Authenticates a locked app once.
    public func authenticateIfNeeded() async {
        guard shouldLock else { return }
        guard !hasAuthenticatedThisSession else { return }
        guard state == .locked else { return }
        await authenticate()
    }

    /// Attempt biometric unlock. On `.failure` / `.unavailable` the state
    /// automatically transitions to `.passcodeFallback` (the failed-biometric
    /// path shows the passcode prompt). Allowed from `.locked` (automatic and
    /// manual triggers) or `.passcodeFallback` (manual retry via the unlock
    /// button).
    public func authenticate() async {
        guard shouldLock else { return }
        guard state == .locked || state == .passcodeFallback else { return }
        guard !hasAuthenticatedThisSession else { return }
        state = .authenticating
        switch await auth.evaluateBiometrics(reason: Self.reason) {
        case .success:
            state = .unlocked
            hasAuthenticatedThisSession = true
            // The system sheet's dismissal `.inactive` may still be in
            // flight; never leave a cover armed over a fresh unlock.
            privacyCover.reset()
        case .failure, .unavailable:
            state = .passcodeFallback
        }
    }

    /// Manual passcode unlock (the passcode fallback prompt's action). Uses
    /// the device passcode via LocalAuthentication.
    public func unlockWithPasscode() async {
        guard shouldLock else { return }
        guard state == .passcodeFallback || state == .locked else { return }
        state = .authenticating
        if await auth.evaluateDevicePasscode(reason: Self.reason) {
            state = .unlocked
            hasAuthenticatedThisSession = true
            // The system sheet's dismissal `.inactive` may still be in
            // flight; never leave a cover armed over a fresh unlock.
            privacyCover.reset()
        } else {
            state = .passcodeFallback
        }
    }

    // MARK: Constants

    /// Persisted-setting key for the in-app App Lock toggle (UserDefaults,
    /// non-secret preference — the lock gates UI only, never Keychain).
    public static let defaultsKey = "fleet.appLock.enabled"

    private static let reason = "Unlock Hermes Fleet"
}
