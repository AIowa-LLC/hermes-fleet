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
    public static func affordance(for approval: WatchApproval, now: Date) -> WatchApprovalAffordance {
        guard WatchFreshnessPolicy.approvalActionable(observedAt: approval.observedAt, now: now) else {
            return .none(reason: approval.observedAt == nil
                ? "Never confirmed by the iPhone. Open on iPhone."
                : "Out of date. Open on iPhone or wait for refresh.")
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

/// Whether an approval the Watch is looking at can still be confirmed pending.
public enum WatchApprovalPresence: Equatable, Sendable {
    case pending
    /// Gone from a snapshot whose machine is actively reporting approvals.
    case resolved
    /// Gone (or never confirmable) but the machine is not reporting now, so
    /// "resolved" would be a guess. Never actionable.
    case unverifiable(String)
}

public enum WatchApprovalScope {
    public static func presence(of approval: WatchApproval, in snapshot: WatchSnapshot?, now: Date) -> WatchApprovalPresence {
        guard let snapshot else { return .unverifiable("No data from iPhone yet.") }
        if snapshot.approvals.contains(where: { $0.id == approval.id }) { return .pending }
        guard let gateway = snapshot.gateways.first(where: { $0.id == approval.gatewayID }) else {
            return .unverifiable("That machine is no longer listed, so this can't be confirmed.")
        }
        let reporting = (gateway.status == .online || gateway.status == .degraded) && gateway.coverage == .reporting
        guard reporting, WatchFreshnessPolicy.approvalActionable(observedAt: gateway.observedAt, now: now) else {
            return .unverifiable("\(gateway.displayName) isn't reporting right now, so Fleet can't confirm this was resolved.")
        }
        return .resolved
    }

    /// "This context": machine, bot AND conversation when one is selected.
    public static func isInContext(_ approval: WatchApproval, _ resolution: WatchContextResolution) -> Bool {
        guard case .resolved(let gateway, let bot, let conversation) = resolution,
              gateway.id == approval.gatewayID else { return false }
        guard let bot else { return true }
        guard approval.profileSlug == bot.ref.profileSlug else { return false }
        guard let conversation else { return true }
        return approval.sessionID == conversation.id
    }
}
