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
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var calls = 0
    var checks: Int { lock.withLock { calls } }

    /// Observe registration, not a guessed number of executor turns. Checking
    /// the condition and registering a waiter use the same lock as evaluate.
    func waitUntilSuspended() async {
        await withCheckedContinuation { continuation in
            let suspended = lock.withLock {
                if !waiting.isEmpty { return true }
                suspensionWaiters.append(continuation)
                return false
            }
            if suspended { continuation.resume() }
        }
    }

    func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
        await withCheckedContinuation { continuation in
            let observers = lock.withLock {
                calls += 1
                waiting.append(continuation)
                let observers = suspensionWaiters
                suspensionWaiters.removeAll()
                return observers
            }
            observers.forEach { $0.resume() }
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
