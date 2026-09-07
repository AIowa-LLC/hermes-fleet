import FleetCore
import SwiftUI

/// U2 (Gold Fleet) — the four pill states the design system renders.
///
/// The plan-of-record hero mock has exactly four pill treatments
/// (online / idle / degraded / offline). Richer domain states
/// (`GatewayStatus`, `BotActivity` in FleetCore) collapse onto these via the
/// initializers below, so every pill in the app renders from one mapping.
/// Presentation-layer only: read-only mapping over FleetCore models.
public enum FleetStatus: String, Hashable, Sendable, CaseIterable {
    /// Running / Online — green.
    case online
    /// Idle / connecting / waiting — amber.
    case idle
    /// Degraded / error / needs attention — red.
    case degraded
    /// Offline / unknown — gray.
    case offline

    /// User-facing pill label (title case, per mock).
    public var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .degraded: "Degraded"
        case .offline: "Offline"
        }
    }

    /// Pill color (dot, label, and ~20% tinted background all derive from it).
    public var color: Color {
        switch self {
        case .online: FleetTheme.statusOnline
        case .idle: FleetTheme.statusIdle
        case .degraded: FleetTheme.statusDegraded
        case .offline: FleetTheme.statusOffline
        }
    }

    /// V5 accessibility (t_b2628d33): the offline gray is 5.31:1 on surface
    /// but only ~4:1 on its own 20% pill tint, so the OFFLINE label renders
    /// in textPrimary (11.7:1 on the tint) — the gray stays on the dot,
    /// tint, and stroke where it is not body copy. Colored states keep
    /// their status color on the label (all AAA on their tints).
    public var labelColor: Color {
        switch self {
        case .online, .idle, .degraded: color
        case .offline: FleetTheme.textPrimary
        }
    }

    /// V5 Differentiate Without Color: SF Symbol reinforcement so status is
    /// never carried by color + dot alone. Decorative — VoiceOver reads the
    /// combined "Status: <label>" (the word is already in the label).
    public var symbolName: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .idle: "circle.dotted"
        case .degraded: "exclamationmark.triangle.fill"
        case .offline: "wifi.slash"
        }
    }

    /// Collapse a gateway connection state onto the four pill states.
    public init(gatewayStatus: GatewayStatus) {
        switch gatewayStatus {
        case .online: self = .online
        case .connecting: self = .idle
        case .degraded: self = .degraded
        case .authenticationRequired, .unsupported, .offline: self = .offline
        }
    }

    /// Collapse a bot activity state onto the four pill states.
    /// `unknown` never fabricates activity — it renders offline-gray.
    public init(activity: BotActivity) {
        switch activity {
        case .working, .thinking, .usingTool: self = .online
        case .waiting, .idle: self = .idle
        case .needsAttention: self = .degraded
        case .offline, .unknown: self = .offline
        }
    }

    /// P0-7 multiplexer presence: the pill's primary signal is whether the
    /// OWNING GATEWAY answered the roster refresh (`presence`), because the
    /// Hermes gateway is a profile multiplexer — every listed profile is
    /// chat-reachable through that one connection. Live `activity` refines
    /// the reachable case only (a reachable bot shows its real work state,
    /// defaulting to online-idle when unobserved); an unreachable or unknown
    /// bot renders offline-gray no matter what stale activity says. This is
    /// what fixes "bots show offline despite server ONLINE": an unobserved
    /// bot on an answering gateway is Online, not Offline.
    public init(activity: BotActivity, presence: BotPresence) {
        switch presence {
        case .reachable:
            switch activity {
            case .working, .thinking, .usingTool: self = .online
            case .waiting, .idle: self = .idle
            case .needsAttention: self = .degraded
            // No live activity signal observed — but the owning gateway just
            // answered, so presence wins: the bot IS online (idle-ready).
            case .offline, .unknown: self = .online
            }
        case .unreachable, .unknown:
            self = .offline
        }
    }
}
