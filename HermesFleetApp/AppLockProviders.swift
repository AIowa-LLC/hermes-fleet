import Foundation
import LocalAuthentication
import FleetCore
import FleetUI

// MARK: - Real LocalAuthentication provider (production)

/// Production `AppLockBiometricAuth` backed by `LAContext`.
///
/// `evaluateBiometrics` uses `.deviceOwnerAuthenticationWithBiometrics`
/// (Face ID / Touch ID). On a failed/unavailable result the controller
/// automatically transitions to the passcode fallback state.
///
/// `evaluateDevicePasscode` uses `.deviceOwnerAuthentication`, which
/// presents the system device-passcode entry — the automatic passcode
/// fallback for H1/R4 (mission: trigger passcode fallback automatically when
/// biometrics fail or are unavailable).
public struct LocalAuthenticationBiometricAuth: AppLockBiometricAuth {

    public init() {}

    public func canEvaluateBiometrics() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public func evaluateBiometrics(reason: String) async -> AppLockAuthResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return ok ? .success : .failure
        } catch {
            return .failure
        }
    }

    public func evaluateDevicePasscode(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: P0.2b user-presence evaluation

    /// One fresh-`LAContext` evaluation for the presence gate. A context is
    /// NEVER reused across actions and no reuse duration is set, so each
    /// privilege-expanding action prompts again. `LAError` codes are mapped so
    /// the gate can tell a user cancel from "biometrics unavailable/locked
    /// out" (passcode fallback) from "no passcode set" (fail closed).
    public func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
        let context = LAContext()
        let laPolicy: LAPolicy = policy == .biometricsOnly
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        if policy == .biometricsOnly {
            context.localizedFallbackTitle = "Use Passcode"
        }
        var error: NSError?
        guard context.canEvaluatePolicy(laPolicy, error: &error) else {
            return Self.outcome(for: error, policy: policy)
        }
        do {
            let ok = try await context.evaluatePolicy(laPolicy, localizedReason: reason)
            return ok ? .success : .failed
        } catch {
            return Self.outcome(for: error, policy: policy)
        }
    }

    static func outcome(for error: Error?, policy: PresencePolicy) -> PresenceOutcome {
        guard let code = (error as? LAError)?.code else {
            return policy == .biometricsOnly ? .biometricsUnavailable : .failed
        }
        switch code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .passcodeNotSet:
            return .passcodeNotSet
        case .userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
            return policy == .biometricsOnly ? .biometricsUnavailable : .failed
        case .authenticationFailed:
            return .failed
        default:
            return policy == .biometricsOnly ? .biometricsUnavailable : .failed
        }
    }
}

// MARK: - Scripted providers (UI-test automation via launch environment)

/// Deterministic scripted `AppLockBiometricAuth` driven by the H1 UI tests.
/// Only activated when the composition root sees `HERMES_FLEET_LOCK_AUTH`;
/// production installs (no env) always use `LocalAuthenticationBiometricAuth`.
public struct ScriptedLockAuth: AppLockBiometricAuth {
    public let biometricResult: AppLockAuthResult
    public let passcodeSucceeds: Bool

    public init(biometricResult: AppLockAuthResult, passcodeSucceeds: Bool) {
        self.biometricResult = biometricResult
        self.passcodeSucceeds = passcodeSucceeds
    }

    public func canEvaluateBiometrics() -> Bool {
        biometricResult != .unavailable
    }

    public func evaluateBiometrics(reason: String) async -> AppLockAuthResult {
        biometricResult
    }

    public func evaluateDevicePasscode(reason: String) async -> Bool {
        passcodeSucceeds
    }

    /// P0.2b: scripted presence evaluation. `.unavailable` biometrics with a
    /// failing passcode models a device with no passcode set.
    public func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
        switch policy {
        case .biometricsOnly:
            switch biometricResult {
            case .success: return .success
            case .failure: return .failed
            case .unavailable: return .biometricsUnavailable
            }
        case .deviceOwner:
            if passcodeSucceeds { return .success }
            return biometricResult == .unavailable ? .passcodeNotSet : .failed
        }
    }
}
