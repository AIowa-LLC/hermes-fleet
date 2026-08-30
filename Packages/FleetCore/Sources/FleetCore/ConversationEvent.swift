import Foundation

/// One streamed conversation event from a Hermes gateway turn.
///
/// Wire shape (verified in `tui_gateway/server.py` `_emit` / `_event_frame`):
/// every event arrives as
/// `{"jsonrpc":"2.0","method":"event","params":{"type":T,"session_id":sid,"payload":{...}}}`
/// and the payload fields below are extracted by the transport client
/// (`GatewayConversationClient` in FleetNetworking). FleetCore owns only the
/// typed vocabulary — the JSON→domain extraction needs `JSONValue` and lives
/// in the networking layer (spec §5.5 tolerant decoding: an unknown event
/// type is preserved as `.unknown`, never fatal).
public enum ConversationEvent: Hashable, Sendable {
    /// `message.start` — a new assistant turn began. No payload on the wire.
    case messageStart(sessionID: String)
    /// `message.delta` — one streamed chunk of the assistant's answer
    /// (`{text, rendered?}`).
    case messageDelta(sessionID: String, text: String, rendered: String?)
    /// `message.interim` — sealed interim assistant text emitted alongside
    /// tool calls (`{text, already_streamed?}`).
    case messageInterim(sessionID: String, text: String, alreadyStreamed: Bool)
    /// `message.complete` — the turn's terminal frame
    /// (`{text, status?, error?, recoverable?, ...}`). `status == "error"`
    /// marks a failed turn; `error` carries the classified failure message.
    case messageComplete(sessionID: String, text: String, status: String?, error: String?)
    /// `thinking.delta` — ambient/thinking text (`{text}`).
    case thinkingDelta(sessionID: String, text: String)
    /// `reasoning.delta` — disclosed reasoning tokens (`{text, verbose?}`).
    case reasoningDelta(sessionID: String, text: String)
    /// `reasoning.available` — reasoning snapshot available (`{text}`).
    case reasoningAvailable(sessionID: String, text: String)
    /// `status.update` — lifecycle status line (`{kind, text}`).
    case statusUpdate(sessionID: String, kind: String, text: String)
    /// `tool.start` — a tool call began (`{tool_id, name, context?, args?}`).
    case toolStart(sessionID: String, toolID: String, name: String, context: String?, argsText: String?)
    /// `tool.generating` — a tool is actively generating (`{name}`).
    case toolGenerating(sessionID: String, name: String)
    /// `tool.progress` — in-flight tool progress (spec §8 supported event;
    /// payload is config-gated upstream, tolerated as a typed case).
    case toolProgress(sessionID: String, toolID: String?, name: String?, text: String?)
    /// `tool.complete` — a tool call finished
    /// (`{tool_id, name, args, result?, summary?, ...}`).
    case toolComplete(sessionID: String, toolID: String, name: String, summary: String?)
    /// `background.complete` — a background turn finished (`{task_id, text}`).
    case backgroundComplete(sessionID: String, taskID: String?, text: String?)
    /// `session.info` — end-of-turn session metadata
    /// (`{model, provider, title?, cwd?, profile_name?, ...}`).
    case sessionInfo(sessionID: String, model: String?, provider: String?, title: String?, cwd: String?, profileName: String?)
    /// `error` — a turn-level error event (`{message, ...}`).
    case error(sessionID: String?, message: String)
    /// Any event type this client does not model — preserved with its raw
    /// wire type so a newer gateway's event is never dropped (spec §5.5).
    case unknown(sessionID: String?, rawType: String)
}

extension ConversationEvent {
    /// The session this event belongs to (nil only for session-less events:
    /// a turn-level `error` or an `unknown` event without a session id).
    public var sessionID: String? {
        switch self {
        case .messageStart(let sid): return sid
        case .messageDelta(let sid, _, _): return sid
        case .messageInterim(let sid, _, _): return sid
        case .messageComplete(let sid, _, _, _): return sid
        case .thinkingDelta(let sid, _): return sid
        case .reasoningDelta(let sid, _): return sid
        case .reasoningAvailable(let sid, _): return sid
        case .statusUpdate(let sid, _, _): return sid
        case .toolStart(let sid, _, _, _, _): return sid
        case .toolGenerating(let sid, _): return sid
        case .toolProgress(let sid, _, _, _): return sid
        case .toolComplete(let sid, _, _, _): return sid
        case .backgroundComplete(let sid, _, _): return sid
        case .sessionInfo(let sid, _, _, _, _, _): return sid
        case .error(let sid, _): return sid
        case .unknown(let sid, _): return sid
        }
    }

    /// Whether this event is the turn-terminal frame (spec §31: a turn ends
    /// with `message.complete` — success or `status == "error"` — or a
    /// turn-level `error`).
    public var isTurnTerminal: Bool {
        switch self {
        case .messageComplete, .error: return true
        default: return false
        }
    }
}
