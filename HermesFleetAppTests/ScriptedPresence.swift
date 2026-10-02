import Foundation
import FleetCore
import FleetUI

/// P0.2b — scripted user-presence authenticator shared by the approval,
/// Home, and App Lock suites. Records every gate invocation so tests can
/// assert the check ran exactly once (or never).
final class ScriptedPresence: AppLockBiometricAuth, @unchecked Sendable {
    private let lock = NSLock()
    private let biometrics: PresenceOutcome
    private let passcode: PresenceOutcome
    private var recorded: [(policy: PresencePolicy, reason: String)] = []

    init(biometrics: PresenceOutcome, passcode: PresenceOutcome = .failed) {
        self.biometrics = biometrics
        self.passcode = passcode
    }

    static var success: ScriptedPresence { ScriptedPresence(biometrics: .success) }

    private func record(_ policy: PresencePolicy, _ reason: String) {
        lock.withLock { recorded.append((policy, reason)) }
    }

    func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
        record(policy, reason)
        return policy == .biometricsOnly ? biometrics : passcode
    }

    /// Number of gate invocations (each starts with one biometrics attempt).
    var presenceChecks: Int {
        lock.withLock { recorded.filter { $0.policy == .biometricsOnly }.count }
    }

    var policies: [PresencePolicy] { lock.withLock { recorded.map(\.policy) } }
    var reasons: [String] { lock.withLock { recorded.map(\.reason) } }

    // Legacy seam (unused by the presence gate).
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .failure }
    func evaluateDevicePasscode(reason: String) async -> Bool { false }
}

/// Suspends a real async boundary so tests can exercise changes during a prompt.
final class SuspendedPresence: AppLockBiometricAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<PresenceOutcome, Never>] = []
    private var calls = 0
    var checks: Int { lock.withLock { calls } }
    func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock { calls += 1; waiting.append(continuation) }
        }
    }
    func complete() {
        let pending = lock.withLock { let result = waiting; waiting.removeAll(); return result }
        pending.forEach { $0.resume(returning: .success) }
    }
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .failure }
    func evaluateDevicePasscode(reason: String) async -> Bool { false }
}
