import Foundation

/// Dogfood r8 — session reasoning level (thinking level) domain.
///
/// Wire ground truth (verified live 2026-09-20 against
/// `~/.hermes/hermes-agent/tui_gateway/`):
/// - Read: `config.get {key: "reasoning", session_id}` → `{value, display}`
///   (methods_config.py:151 `_cfg_get_reasoning`). Resolution order:
///   session override → live agent config → global YAML default.
/// - Write: `config.set {key: "reasoning", value, scope: "session",
///   session_id}` (methods_config_set.py:306 `_set_reasoning`) → stores
///   `create_reasoning_override` on the session; result `{key, value,
///   scope}`. SESSION-SCOPED by design — "a menu pick must not rewrite the
///   global" (the gateway's own comment). The global
///   `agent.reasoning_effort` stays the owner's knob, never the app's.
/// - Accepted values — `hermes_constants.parse_reasoning_effort`, executed
///   live: `none | minimal | low | medium | high` (and `false → none`).
///   Anything else — including numerics like "5.6" — returns None and the
///   setter errors 4002. The five words are the ENTIRE control surface.
public enum FleetReasoningLevel: String, CaseIterable, Codable, Sendable, Hashable {
    /// Thinking disabled. The wire word is `none` (NOT the case name).
    case off = "none"
    case minimal
    case low
    case medium
    case high

    /// Stop index along the slider (0…4) — `allCases` order is stop order.
    public var stopIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// Plain-English label (Tony's plain-words rule: never jargon).
    public var label: String {
        switch self {
        case .off: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The gateway's default when nothing overrides (`_cfg_get_reasoning`
    /// falls back to "medium").
    public static let defaultLevel: FleetReasoningLevel = .medium
}

/// One `config.get reasoning` readback. `level` is nil when the gateway
/// reports a word Fleet does not know (a future/unknown effort tier): the
/// chip then shows `rawValue` verbatim and the slider marks no stop — an
/// honest unknown, never a guessed mapping.
public struct ReasoningState: Equatable, Sendable {
    /// The mapped level, nil on an unknown readback word.
    public let level: FleetReasoningLevel?
    /// The wire word verbatim (chip text when `level` is nil).
    public let rawValue: String
    /// Reasoning VISIBILITY readback (`show|hide`) — carried for a future
    /// control; the slider never writes it.
    public let display: String?

    public init(level: FleetReasoningLevel?, rawValue: String, display: String?) {
        self.level = level
        self.rawValue = rawValue
        self.display = display
    }
}

/// r8 seam: read + session-scoped write of the session's reasoning level.
/// Lives in FleetCore so FleetUI never imports FleetNetworking (M0 guard);
/// the concrete `GatewayReasoningClient` is injected at the composition
/// root, mirroring `ApprovalsProviding` (R9-T1).
///
/// Fail-closed by design: an implementation that cannot reach the gateway
/// THROWS — a failed level change must never look like success (the session
/// would silently reason at the wrong effort).
public protocol ReasoningProviding: Sendable {
    /// `config.get reasoning` for one session.
    func reasoning(sessionID: String) async throws -> ReasoningState

    /// `config.set reasoning scope=session` — flips ONLY this session's
    /// override, never the global config.
    /// - Returns: the level the gateway reports back (fail-closed on a
    ///   mismatch — the caller shows an error, never a fake success).
    func setReasoning(_ level: FleetReasoningLevel, sessionID: String) async throws -> FleetReasoningLevel
}

/// Sessions whose concrete type carries a reasoning seam. Follows the
/// `ApprovalsCapable` sub-protocol pattern verbatim (one cast at VM build
/// time; deliberately NOT a same-named extension property on
/// `ConversationSessionProviding` — that recurses through
/// swift_dynamicCast, see Approvals.swift).
public protocol ReasoningCapable: ConversationSessionProviding {
    var reasoning: any ReasoningProviding { get }
}

/// Fail-closed default: sessions without the seam throw instead of
/// pretending (the UI hides the chip entirely — honest absence).
public struct UnsupportedReasoning: ReasoningProviding {
    public init() {}

    public func reasoning(sessionID: String) async throws -> ReasoningState {
        throw ConversationError.notConnected
    }

    public func setReasoning(_ level: FleetReasoningLevel, sessionID: String) async throws -> FleetReasoningLevel {
        throw ConversationError.notConnected
    }
}
