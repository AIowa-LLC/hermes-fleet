import Foundation

/// Dogfood top-space fix — priority policy for the conversation banner chrome.
///
/// The conversation previously STACKED every status surface above the
/// transcript (integrity notice, replay notice, phase banner, history
/// notice, error banner — each its own bar). The compact chrome renders
/// exactly ONE banner: the highest-priority surface for the current state.
///
/// Priority (highest first):
///
///     authRequired > disconnected > failed > progress > informational
///
/// Networking, session lifecycle, and reconnect semantics are untouched —
/// this is presentation selection only, and it is pure so it is directly
/// unit-testable.
enum ConversationBannerPriority: Int, Comparable, Sendable {
    /// Replay / integrity / cold-cache notices — context, not failure.
    case informational = 0
    /// opening / connecting / reconnecting — transient progress.
    case progress = 1
    /// Classified failures, history-load errors, surfaced session errors.
    case failed = 2
    /// Socket dropped mid-session; replayed history is shown.
    case disconnected = 3
    /// 4401 — explicit re-auth required (never a silent retry, M11).
    case authRequired = 4

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One selectable banner surface.
enum ConversationBannerKind: Equatable, Sendable {
    /// Integrity mismatch notice (destructive tint, informational band).
    case integrity
    /// Post-reconnect replay hydration notice.
    case replay
    /// session.create / session.resume in flight.
    case opening
    /// Gateway socket connecting.
    case connecting
    /// Reconnect + replay hydration in flight.
    case reconnecting
    /// Socket dropped mid-session; replayed history shown.
    case disconnected
    /// 4401 — authentication required.
    case authRequired
    /// A classified failure or surfaced error.
    case failed
    /// Cold-start persisted history notice.
    case info

    var priority: ConversationBannerPriority {
        switch self {
        case .authRequired: return .authRequired
        case .disconnected: return .disconnected
        case .failed: return .failed
        case .opening, .connecting, .reconnecting: return .progress
        case .integrity, .replay, .info: return .informational
        }
    }

    /// SF Symbol for the banner glyph (spinner replaces it for progress).
    var symbolName: String {
        switch self {
        case .integrity: return "checkmark.shield"
        case .replay: return "arrow.triangle.2.circlepath"
        case .opening: return "hourglass"
        case .connecting: return "bolt.horizontal"
        case .reconnecting: return "arrow.clockwise"
        case .disconnected: return "wifi.slash"
        case .authRequired: return "exclamationmark.lock"
        case .failed: return "exclamationmark.triangle"
        case .info: return "internaldrive"
        }
    }

    /// Progress states render a spinner instead of a static glyph.
    var showsSpinner: Bool {
        switch self {
        case .opening, .connecting, .reconnecting: return true
        default: return false
        }
    }
}

/// The selected banner: its kind and the exact text the chrome renders.
struct ConversationBanner: Equatable, Sendable {
    let kind: ConversationBannerKind
    let text: String

    var priority: ConversationBannerPriority { kind.priority }
}

/// Selects the single banner the conversation chrome renders for a state.
///
/// Mirrors the previous stacked surfaces exactly (same copy, same states);
/// the only behavioral change is that when more than one would have
/// rendered, the highest-priority one wins instead of stacking. During
/// `.streaming` the settled-state notices (replay / integrity) stay hidden,
/// exactly as before.
enum ConversationBannerSelector {
    static let disconnectedText = "Connection lost — replayed history is shown. Reconnect to continue."
    static let openingText = "Opening conversation…"
    static let connectingText = "Connecting…"
    static let reconnectingText = "Reconnecting…"
    static let authRequiredDefaultText = "Authentication required."
    static let hydratedFromCacheText = "Showing saved history — connecting for live updates."

    static func select(
        phase: ConversationViewModel.Phase,
        integrityNotice: String?,
        replayNotice: String?,
        hydratedFromCache: Bool,
        historyLoadError: String?,
        errorMessage: String?
    ) -> ConversationBanner? {
        switch phase {
        case .authRequired:
            return ConversationBanner(kind: .authRequired, text: errorMessage ?? authRequiredDefaultText)
        case .disconnected:
            return ConversationBanner(kind: .disconnected, text: disconnectedText)
        case .failed(let detail):
            return ConversationBanner(kind: .failed, text: detail)
        case .idle, .opening:
            return ConversationBanner(kind: .opening, text: openingText)
        case .connecting:
            return ConversationBanner(kind: .connecting, text: connectingText)
        case .reconnecting:
            return ConversationBanner(kind: .reconnecting, text: reconnectingText)
        case .ready, .streaming:
            // Failures win over context notices; the streaming phase hides
            // replay/integrity notices entirely (they are settled-state
            // context, and the turn in flight owns the surface).
            if let historyLoadError {
                return ConversationBanner(kind: .failed, text: historyLoadError)
            }
            if let errorMessage {
                return ConversationBanner(kind: .failed, text: errorMessage)
            }
            if phase != .streaming, let integrityNotice {
                return ConversationBanner(kind: .integrity, text: integrityNotice)
            }
            if phase != .streaming, let replayNotice {
                return ConversationBanner(kind: .replay, text: replayNotice)
            }
            if hydratedFromCache {
                return ConversationBanner(kind: .info, text: hydratedFromCacheText)
            }
            return nil
        }
    }
}
