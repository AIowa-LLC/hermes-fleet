import Foundation

/// What the Watch may offer for one approval. It never widens the phone's
/// rules: only Deny, and Approve-once for short, fully-visible commands.
public enum WatchApprovalAffordance: Equatable, Sendable {
    case denyOrApproveOnce
    case denyOnly(handOffReason: String)
    /// Neither: too old to trust, show refresh/phone only.
    case none(reason: String)
}

public enum WatchApprovalPolicy {
    public static func affordance(for approval: WatchApproval, snapshotBuiltAt: Date, now: Date) -> WatchApprovalAffordance {
        guard WatchFreshnessPolicy.approvalsActionable(snapshotBuiltAt: snapshotBuiltAt, now: now) else {
            return .none(reason: "Out of date. Open on iPhone or wait for refresh.")
        }
        if approval.requiresFullReview {
            return .denyOnly(handOffReason: "Long command. Review it in full on iPhone.")
        }
        if !approval.choices.isEmpty, !approval.choices.contains("once") {
            return .denyOnly(handOffReason: "Approve isn't offered for this request. Use iPhone.")
        }
        return .denyOrApproveOnce
    }
}

/// Phone-side revalidation: given what the Watch saw and what the gateway
/// reports as pending RIGHT NOW, decide whether acting is still safe.
public enum WatchApprovalRevalidation: Equatable, Sendable {
    case proceed
    case alreadyResolved
    case changed
}

public enum WatchApprovalRevalidator {
    /// `current` must come from a fresh `pendingApprovals` call on the
    /// ORIGINAL gateway and session — never from the Watch's cache.
    public static func validate(
        request: WatchApprovalRequest, currentCommandDigest: String?, stillPending: Bool
    ) -> WatchApprovalRevalidation {
        guard stillPending, let digest = currentCommandDigest else { return .alreadyResolved }
        return digest == request.commandDigest ? .proceed : .changed
    }
}

/// Phone-side duplicate and replay protection for approvals. State survives
/// only for the process lifetime plus an optional persisted set, so a stale
/// replayed WatchConnectivity message cannot re-approve a resolved request.
public struct WatchApprovalLedger: Sendable, Codable, Equatable {
    public enum Entry: Sendable, Codable, Equatable {
        case inFlight
        case finished(WatchApprovalOutcome)
    }

    private var byUUID: [String: Entry] = [:]
    private var byKey: [String: String] = [:]
    private var order: [String] = []
    public static let capacity = 200

    public init() {}

    public enum Admission: Equatable, Sendable {
        case admit
        /// Same request UUID seen before.
        case duplicate(Entry)
        /// A different UUID is already acting on this approval.
        case busy
        /// This approval was already finished by an earlier decision.
        case alreadyFinished(WatchApprovalOutcome)
    }

    public mutating func admit(_ request: WatchApprovalRequest) -> Admission {
        if let prior = byUUID[request.requestUUID] { return .duplicate(prior) }
        if let uuid = byKey[request.approvalKey], let entry = byUUID[uuid] {
            switch entry {
            case .inFlight: return .busy
            case .finished(let outcome):
                switch outcome {
                case .applied, .alreadyResolved, .expired:
                    return .alreadyFinished(outcome)
                case .changed, .staleSnapshot, .handOffToPhone, .unavailable, .duplicate, .uncertain, .failed:
                    break
                }
            }
        }
        byUUID[request.requestUUID] = .inFlight
        byKey[request.approvalKey] = request.requestUUID
        order.append(request.requestUUID)
        trim()
        return .admit
    }

    public mutating func finish(_ request: WatchApprovalRequest, outcome: WatchApprovalOutcome) {
        byUUID[request.requestUUID] = .finished(outcome)
    }

    private mutating func trim() {
        while order.count > Self.capacity {
            let old = order.removeFirst()
            byUUID[old] = nil
            byKey = byKey.filter { $0.value != old }
        }
    }
}
