import Foundation

/// Typed bot delivery/turn failure reasons — EXACT wire spelling from
/// `tools/bot_failure_reasons.py` (ALL_REASONS, 13 values) plus the relay
/// refusal reason `target_busy` (tui_gateway/methods_bot_relay.py:142-143).
///
/// These strings travel in `data.reason` alongside free-text error messages;
/// the client must key recovery actions off the typed reason, never parse the
/// prose. Auto-retry classification: bot_failure_reasons.py:52-63.
public enum BotFailureReason: String, Hashable, Sendable, Codable, CaseIterable {
    // Platform-side (bot_failure_reasons.py:16-20)
    case runtimeOffline = "runtime_offline"
    case queuedExpired = "queued_expired"
    case deliveryTimeout = "delivery_timeout"
    case agentBlocked = "agent_blocked"
    case cancelled = "cancelled"
    // Agent-side (bot_failure_reasons.py:23-30)
    case providerAuthOrAccess = "provider_auth_or_access"
    case providerQuotaLimit = "provider_quota_limit"
    case providerRateLimit = "provider_rate_limit"
    case providerServerError = "provider_server_error"
    case contextOverflow = "context_overflow"
    case missingConfig = "missing_config"
    case modelUnavailable = "model_unavailable"
    case unknown = "unknown"
    // Relay refusal (methods_bot_relay.py:143) — not in ALL_REASONS but a
    // structured reason on the wire; modeled separately here.
    public static let targetBusyRawValue = "target_busy"

    /// Recovery action vocabulary (bot_failure_reasons.py:52-63):
    /// `resume` (auto-retryable), `compress_then_resume`, `none`.
    public enum RecoveryAction: String, Hashable, Sendable, Codable {
        case resume
        case compressThenResume = "compress_then_resume"
        case none
    }

    /// The recovery action this reason admits. Auth/quota/config/model
    /// failures are NEVER auto-retried (`none`).
    public var recoveryAction: RecoveryAction {
        switch self {
        case .runtimeOffline, .deliveryTimeout, .providerRateLimit, .providerServerError:
            return .resume
        case .contextOverflow:
            return .compressThenResume
        case .queuedExpired, .agentBlocked, .cancelled,
             .providerAuthOrAccess, .providerQuotaLimit,
             .missingConfig, .modelUnavailable, .unknown:
            return .none
        }
    }

    /// Whether the reason is in the auto-retryable set (retry action `resume`).
    public var isAutoRetryable: Bool { recoveryAction == .resume }

    /// Attention-badge class (Desktop data.ts:51-59): these reasons surface a
    /// persistent needs-attention badge, never a transient toast.
    public var requiresAttention: Bool {
        switch self {
        case .agentBlocked, .providerAuthOrAccess, .providerQuotaLimit, .missingConfig:
            return true
        default:
            return false
        }
    }

    /// Tolerant decode from the wire string; unknown spellings decode to
    /// `.unknown` (never fail — the enum is closed upstream but old clients
    /// must degrade honestly).
    public init(wireValue: String) {
        self = BotFailureReason(rawValue: wireValue) ?? .unknown
    }
}

/// A typed failure payload as it appears on the wire: free-text `error` plus
/// structured `reason` (e.g. bot_relay.deliver error 5092 `data.reason`).
public struct TypedBotFailure: Hashable, Sendable, Codable {
    public let reason: BotFailureReason
    public let message: String?

    public init(reason: BotFailureReason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }

    public init(wireReason: String, message: String? = nil) {
        self.init(reason: BotFailureReason(wireValue: wireReason), message: message)
    }
}
