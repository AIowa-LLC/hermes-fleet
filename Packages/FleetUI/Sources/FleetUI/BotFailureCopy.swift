import SwiftUI
import FleetCore

/// TRUE BOTS MODE slice 5 (D22) — typed failure/attention copy.
///
/// Per-type user copy + recovery actions for every `BotFailureReason` using
/// the ACTUAL wire spelling (tools/bot_failure_reasons.py ALL_REASONS at
/// 08b140d, plus the relay refusal `target_busy`, methods_bot_relay.py:143).
/// NEVER generic-only: each failure type renders cause-specific "what
/// happened + what to do" copy and a type-appropriate action set.
///
/// The mapping lives in FleetUI (presentation) keyed off the FleetCore enum —
/// FleetUI still never imports FleetNetworking.
public enum BotFailureCopy {

    /// The recovery actions offered for one failure type (typed, per-type).
    public enum Action: Hashable, Sendable, Identifiable {
        /// Retry now (offered when the wire admits a retry).
        case retry
        /// Compress context then resume (context_overflow).
        case compressThenResume
        /// Open the bot's config (missing_config / agent_blocked).
        case openSettings
        /// Sign in again to the provider (provider_auth_or_access).
        case reauthenticate
        /// Wait + auto-retry notice (rate limit / server error).
        case waitAndAutoRetry
        /// Check quota/billing (provider_quota_limit).
        case checkQuota
        /// Pick another model (model_unavailable).
        case pickModel
        /// Reconnect the runtime (runtime_offline).
        case reconnectRuntime

        public var id: String {
            switch self {
            case .retry: return "retry"
            case .compressThenResume: return "compress_then_resume"
            case .openSettings: return "open_settings"
            case .reauthenticate: return "reauthenticate"
            case .waitAndAutoRetry: return "wait_auto_retry"
            case .checkQuota: return "check_quota"
            case .pickModel: return "pick_model"
            case .reconnectRuntime: return "reconnect_runtime"
            }
        }

        /// Button title rendered in the failure card.
        public var title: String {
            switch self {
            case .retry: return "Retry"
            case .compressThenResume: return "Compress & resume"
            case .openSettings: return "Open Settings"
            case .reauthenticate: return "Re-authenticate"
            case .waitAndAutoRetry: return "It retries itself"
            case .checkQuota: return "Check quota"
            case .pickModel: return "Pick another model"
            case .reconnectRuntime: return "Reconnect gateway"
            }
        }

        /// SF Symbol for the action row.
        public var symbol: String {
            switch self {
            case .retry: return "arrow.clockwise"
            case .compressThenResume: return "arrow.down.doc"
            case .openSettings: return "gearshape"
            case .reauthenticate: return "key"
            case .waitAndAutoRetry: return "clock"
            case .checkQuota: return "chart.pie"
            case .pickModel: return "cpu"
            case .reconnectRuntime: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    /// Short cause title (sentence case, one or two words).
    public static func title(for reason: BotFailureReason) -> String {
        switch reason {
        case .runtimeOffline: return "Runtime offline"
        case .queuedExpired: return "Queued message expired"
        case .deliveryTimeout: return "Delivery timed out"
        case .agentBlocked: return "Bot is blocked"
        case .cancelled: return "Cancelled"
        case .providerAuthOrAccess: return "Provider sign-in needed"
        case .providerQuotaLimit: return "Provider quota limit"
        case .providerRateLimit: return "Rate limited"
        case .providerServerError: return "Provider server error"
        case .contextOverflow: return "Context too long"
        case .missingConfig: return "Missing configuration"
        case .modelUnavailable: return "Model unavailable"
        case .unknown: return "Unknown failure"
        }
    }

    /// Cause-specific "what happened + what to do" copy (sentence case,
    /// plain language, no jargon, no secrets, never generic).
    public static func message(for reason: BotFailureReason) -> String {
        switch reason {
        case .runtimeOffline:
            return "The gateway runtime wasn't running when this was sent. Reconnect and retry — it may need a restart."
        case .queuedExpired:
            return "This message waited in queue too long before delivery and expired. Send it again."
        case .deliveryTimeout:
            return "Delivery took too long and timed out. It can be retried automatically."
        case .agentBlocked:
            return "The bot stopped and needs a person to unblock it. Open its chat and clear the block."
        case .cancelled:
            return "This run was cancelled. Nothing is wrong — start it again if you still want it."
        case .providerAuthOrAccess:
            return "The bot's model provider rejected its sign-in. Re-authenticate the provider in the gateway settings."
        case .providerQuotaLimit:
            return "The model provider reports quota or billing exhausted. Check the provider account, then retry."
        case .providerRateLimit:
            return "The provider is rate limiting requests right now. Wait a moment — Fleet retries this automatically."
        case .providerServerError:
            return "The model provider had a server error. Wait a moment — Fleet retries this automatically."
        case .contextOverflow:
            return "This conversation grew past the model's context limit. Compress the context, then resume."
        case .missingConfig:
            return "The bot is missing required configuration (model, provider, or credentials). Open its settings to finish setup."
        case .modelUnavailable:
            return "The configured model isn't available right now. Pick another model for this bot."
        case .unknown:
            return "Something failed and the gateway didn't say what. Retry, and check the gateway logs if it keeps happening."
        }
    }

    /// Per-type recovery actions (never generic-only; never offers retry for
    /// types the wire marks `none`).
    public static func actions(for reason: BotFailureReason) -> [Action] {
        switch reason {
        case .runtimeOffline:
            return [.reconnectRuntime, .retry]
        case .queuedExpired:
            return [.retry]
        case .deliveryTimeout:
            return [.retry]
        case .agentBlocked:
            return [.openSettings]
        case .cancelled:
            return [.retry]
        case .providerAuthOrAccess:
            return [.reauthenticate, .openSettings]
        case .providerQuotaLimit:
            return [.checkQuota]
        case .providerRateLimit:
            return [.waitAndAutoRetry]
        case .providerServerError:
            return [.waitAndAutoRetry]
        case .contextOverflow:
            return [.compressThenResume]
        case .missingConfig:
            return [.openSettings]
        case .modelUnavailable:
            return [.pickModel]
        case .unknown:
            return [.retry]
        }
    }

    /// Wire-spelling badge (mono caption; honest identity for power users).
    public static func wireBadge(for reason: BotFailureReason) -> String {
        reason.rawValue
    }

    /// `target_busy` relay refusal (methods_bot_relay.py:143) — a static
    /// raw value on the FleetCore enum, exposed through the same typed copy
    /// surface.
    public static let targetBusyTitle = "Bot is busy"
    public static let targetBusyMessage =
        "The bot is busy with another delivery. Fleet will show it as busy — try again in a moment."

    /// The complete typed-failure surface for one failure (title + message +
    /// actions + wire badge) — the single value views render from.
    public struct Surface: Hashable, Sendable {
        public let reason: BotFailureReason
        public let title: String
        public let message: String
        public let actions: [Action]
        public let wireBadge: String
        public let requiresAttention: Bool

        public init(_ reason: BotFailureReason) {
            self.reason = reason
            self.title = BotFailureCopy.title(for: reason)
            self.message = BotFailureCopy.message(for: reason)
            self.actions = BotFailureCopy.actions(for: reason)
            self.wireBadge = BotFailureCopy.wireBadge(for: reason)
            self.requiresAttention = reason.requiresAttention
        }
    }
}
