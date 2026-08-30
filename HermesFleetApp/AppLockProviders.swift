import Foundation
import LocalAuthentication
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
}
