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
}
