import Foundation

// P0.2b — single "user presence" gate for privilege-expanding actions.
//
// The platform seam (LocalAuthentication) lives in the app target; this file
// holds only the platform-free decision logic so it can be unit-tested with a
// stub evaluator: try biometrics first, fall back to the device passcode only
// when biometrics cannot run (unavailable / locked out / not enrolled / the
// user tapped the system "Use Passcode" button), and never turn a user
// cancellation into a second prompt.

/// What the user is being asked to prove presence for. Each action carries its
/// own specific system-prompt reason so the user knows exactly what they are
/// authorizing.
public enum PresenceAction: Equatable, Sendable {
    case approveOnce
    case approveForSession
    case approveAlways
    case enableYolo
    case turnOffAppLock
    case enterSudoPassword
    case enterSecret

    /// The action that corresponds to an approval answer. `.deny` is never
    /// gated; callers must not ask for presence on it (returns `nil`).
    public init?(approvalChoice: ApprovalChoice) {
        switch approvalChoice {
        case .once: self = .approveOnce
        case .session: self = .approveForSession
        case .always: self = .approveAlways
        case .deny: return nil
        }
    }

    /// The `localizedReason` shown in the system authentication prompt.
    public var localizedReason: String {
        switch self {
        case .approveOnce: return "Approve a dangerous command"
        case .approveForSession: return "Approve a command for this session"
        case .approveAlways: return "Save an always-allow rule"
        case .enableYolo: return "Enable YOLO for this session"
        case .turnOffAppLock: return "Turn off App Lock"
        case .enterSudoPassword: return "Enter your sudo password for the agent"
        case .enterSecret: return "Enter a secret for the agent"
        }
    }
}

/// Which system authentication policy one evaluation should use.
public enum PresencePolicy: Equatable, Sendable {
    /// Face ID / Touch ID only (`.deviceOwnerAuthenticationWithBiometrics`).
    case biometricsOnly
    /// Biometrics with the system passcode UI (`.deviceOwnerAuthentication`).
    case deviceOwner
}

/// The raw outcome of one platform evaluation.
public enum PresenceOutcome: Equatable, Sendable {
    case success
    /// The user (or system/app) dismissed the prompt.
    case cancelled
    /// The presented check did not match / was rejected.
    case failed
    /// Biometrics cannot run right now (not enrolled, unavailable, locked out,
    /// or the user asked for the passcode). The passcode fallback applies.
    case biometricsUnavailable
    /// The device has no passcode set: no user-presence check is possible.
    case passcodeNotSet
}

/// The gate's decision for a privilege-expanding action.
public enum PresenceResult: Equatable, Sendable {
    case verified
    case cancelled
    case failed
    case passcodeNotSet
}

/// Platform seam for one evaluation. Each call must use a FRESH authentication
/// context: an authenticated context is never reused across actions.
public protocol PresenceEvaluating: Sendable {
    func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome
}

/// Decision logic: biometrics first, passcode fallback only when biometrics
/// cannot run. Fails closed on every non-success path.
public struct UserPresenceGate: Sendable {
    private let evaluator: any PresenceEvaluating

    public init(evaluator: any PresenceEvaluating) {
        self.evaluator = evaluator
    }

    public func verify(_ action: PresenceAction) async -> PresenceResult {
        let reason = action.localizedReason
        switch await evaluator.evaluate(policy: .biometricsOnly, reason: reason) {
        case .success:
            return .verified
        case .cancelled:
            // No fallback loop after an explicit cancel.
            return .cancelled
        case .failed:
            // A mismatch stays blocked; the user may retry the action.
            return .failed
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometricsUnavailable:
            break
        }
        switch await evaluator.evaluate(policy: .deviceOwner, reason: reason) {
        case .success: return .verified
        case .cancelled: return .cancelled
        case .failed: return .failed
        // Biometrics already reported unavailable; if the passcode policy also
        // cannot evaluate there is nothing left to verify with.
        case .passcodeNotSet, .biometricsUnavailable: return .passcodeNotSet
        }
    }
}
