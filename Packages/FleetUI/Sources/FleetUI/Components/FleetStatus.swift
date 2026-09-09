import FleetCore
import SwiftUI

/// FOS-7 (SPEC §7 vocabulary + §14 tokens) — the pill states the design
/// system renders. The old four-state compression (online/idle/degraded/
/// offline) is RETIRED: presence (reachable), execution, attention, and
/// freshness are now distinct, and `unknown` never collapses into idle or
/// offline. Every state is a symbol + word pair — color is reinforcement,
/// never the only differentiator.
///
/// Presentation-layer only: read-only mapping over FleetCore models.
public enum FleetStatus: Hashable, Sendable {

    /// Exact executing phase (SPEC §7: Working / Thinking / Using tool).
    public enum ExecutingState: String, Hashable, Sendable, CaseIterable {
        case working
        case thinking
        case usingTool

        public var label: String {
            switch self {
            case .working: "Working"
            case .thinking: "Thinking"
            case .usingTool: "Using tool"
            }
        }
    }

    /// Reachable / connected — green checkmark; connectivity only, it does
    /// NOT mean working (SPEC §14 online row).
    case online
    /// Authoritative execution in progress — cyan signal, exact phase word.
    case executing(ExecutingState)
    /// Current run explicitly waits for a dependency, response, or approval —
    /// secondary label, no alarm tint (SPEC §14 waiting row).
    case waiting
    /// Unresolved human decision/repair with an owner — amber person cue,
    /// "Needs you" (SPEC §14 needs-intervention row).
    case needsYou
    /// Current source rejects/misses required authentication — amber,
    /// "Sign in required"; kept separate from generic degradation (SPEC §7).
    case authRequired
    /// Classified source/operation problem with partial service — orange
    /// triangle, precise reason at the call site (SPEC §14 degraded row).
    case degraded
    /// Phone connection failed / roster source unreachable — secondary
    /// label + wifi.slash; never claims remote execution stopped.
    case offline
    /// No admissible observation — secondary label + question mark;
    /// NEVER mapped to idle or offline (SPEC §7 unknown row).
    case unknown

    /// The canonical presentation states (for previews and tests).
    public static let allCases: [FleetStatus] = [
        .online, .executing(.working), .executing(.thinking), .executing(.usingTool),
        .waiting, .needsYou, .authRequired, .degraded, .offline, .unknown,
    ]

    /// User-facing pill word (exact vocabulary, SPEC §7).
    public var label: String {
        switch self {
        case .online: "Online"
        case .executing(let state): state.label
        case .waiting: "Waiting"
        case .needsYou: "Needs you"
        case .authRequired: "Sign in required"
        case .degraded: "Degraded"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }

    /// Symbol color. Waiting/offline/unknown deliberately take NO alarm tint —
    /// they resolve as secondary label (SPEC §14 token table).
    public var color: Color {
        switch self {
        case .online: FleetTheme.statusOnline
        case .executing: FleetTheme.statusExecuting
        case .waiting: FleetTheme.textSecondary
        case .needsYou: FleetTheme.statusNeedsIntervention
        case .authRequired: FleetTheme.statusNeedsIntervention
        case .degraded: FleetTheme.statusDegraded
        case .offline: FleetTheme.textSecondary
        case .unknown: FleetTheme.textSecondary
        }
    }

    /// Pill word color: primary label with a colored glyph — SPEC §14
    /// ("Status text normally uses primary label with a colored glyph";
    /// Increase Contrast replaces colored status text with primary text,
    /// which is already the default here).
    public var labelColor: Color { FleetTheme.textPrimary }

    /// Distinct reinforcement symbol per state (Differentiate Without Color
    /// and ordinary rendering — symbol + word pairs are ALWAYS shown).
    public var symbolName: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .executing(.working): "gearshape.fill"
        case .executing(.thinking): "brain.head.profile"
        case .executing(.usingTool): "wrench.and.screwdriver.fill"
        case .waiting: "hourglass"
        case .needsYou: "person.crop.circle.badge.exclamationmark"
        case .authRequired: "lock.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .offline: "wifi.slash"
        case .unknown: "questionmark.circle"
        }
    }

    /// Collapse a gateway connection state onto the presentation vocabulary.
    /// `authenticationRequired` stays its own amber state (SPEC §7);
    /// `unsupported` renders degraded (a classified source problem), not
    /// silent offline; a never-classified source renders unknown, not offline.
    public init(gatewayStatus: GatewayStatus) {
        switch gatewayStatus {
        case .online: self = .online
        case .connecting: self = .waiting
        case .degraded: self = .degraded
        case .authenticationRequired: self = .authRequired
        case .unsupported: self = .degraded
        case .offline: self = .offline
        }
    }

    /// P0-7 multiplexer presence: the pill's primary signal is whether the
    /// OWNING GATEWAY answered the roster refresh (`presence`), because the
    /// Hermes gateway is a profile multiplexer — every listed profile is
    /// chat-reachable through that one connection. Live `activity` refines
    /// the reachable case (exact execution word when observed, waiting when
    /// waiting, attention when flagged, Online when unobserved-but-reachable);
    /// an unreachable bot renders offline and a never-classified source
    /// renders unknown — never idle (SPEC §7).
    public init(activity: BotActivity, presence: BotPresence) {
        switch presence {
        case .reachable:
            switch activity {
            case .working: self = .executing(.working)
            case .thinking: self = .executing(.thinking)
            case .usingTool: self = .executing(.usingTool)
            case .waiting: self = .waiting
            case .needsAttention: self = .needsYou
            case .idle, .offline, .unknown:
                // No live activity signal observed — but the owning gateway
                // just answered, so presence wins: the bot IS online. The
                // green word "Online" claims connectivity only, never work.
                self = .online
            }
        case .unreachable:
            self = .offline
        case .unknown:
            self = .unknown
        }
    }
}
