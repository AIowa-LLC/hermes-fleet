import Foundation

/// One streamed conversation event from a Hermes gateway turn.
///
/// Wire shape (verified in `tui_gateway/server.py` `_emit` / `_event_frame`):
/// every event arrives as
/// `{"jsonrpc":"2.0","method":"event","params":{"type":T,"session_id":sid,"seq":N,"payload":{...}}}`
/// and the payload fields below are extracted by the transport client
/// (`GatewayConversationClient` in FleetNetworking). FleetCore owns only the
/// typed vocabulary — the JSON→domain extraction needs `JSONValue` and lives
/// in the networking layer (spec §5.5 tolerant decoding: an unknown event
/// type is preserved as `.unknown`, never fatal).
///
/// Last-Event-ID (t_8401d3c3): the gateway stamps every per-session event
/// with a monotonic `seq` (`event_replay.py` — one counter per session id,
/// assigned under a lock at emit time). `event.seq` carries that stamp into
/// the conversation domain so the client can (a) track its last applied
/// event id per stream, (b) validate continuity, and (c) resume exactly
/// where it stopped via `session.events.since(last_seen)`. `nil` seq (a
/// session-less or fixture event) is tolerated — continuity tracking simply
/// ignores it (last-event-id semantics are only defined for stamped events).
public enum ConversationEvent: Hashable, Sendable {
    /// `message.start` — a new assistant turn began. No payload on the wire.
    case messageStart(sessionID: String, seq: Int? = nil)
    /// `message.delta` — one streamed chunk of the assistant's answer
    /// (`{text, rendered?}`).
    case messageDelta(sessionID: String, text: String, rendered: String?, seq: Int? = nil)
    /// `message.interim` — sealed interim assistant text emitted alongside
    /// tool calls (`{text, already_streamed?}`).
    case messageInterim(sessionID: String, text: String, alreadyStreamed: Bool, seq: Int? = nil)
    /// `message.complete` — the turn's terminal frame
    /// (`{text, status?, error?, recoverable?, ...}`). `status == "error"`
    /// marks a failed turn; `error` carries the classified failure message.
    case messageComplete(sessionID: String, text: String, status: String?, error: String?, seq: Int? = nil)
    /// `thinking.delta` — ambient/thinking text (`{text}`).
    case thinkingDelta(sessionID: String, text: String, seq: Int? = nil)
    /// `reasoning.delta` — disclosed reasoning tokens (`{text, verbose?}`).
    case reasoningDelta(sessionID: String, text: String, seq: Int? = nil)
    /// `reasoning.available` — reasoning snapshot available (`{text}`).
    case reasoningAvailable(sessionID: String, text: String, seq: Int? = nil)
    /// `status.update` — lifecycle status line (`{kind, text}`).
    case statusUpdate(sessionID: String, kind: String, text: String, seq: Int? = nil)
    /// `tool.start` — a tool call began (`{tool_id, name, context?, args?}`).
    case toolStart(sessionID: String, toolID: String, name: String, context: String?, argsText: String?, seq: Int? = nil)
    /// `tool.generating` — a tool is actively generating (`{name}`).
    case toolGenerating(sessionID: String, name: String, seq: Int? = nil)
    /// `tool.progress` — in-flight tool progress (spec §8 supported event;
    /// payload is config-gated upstream, tolerated as a typed case).
    case toolProgress(sessionID: String, toolID: String?, name: String?, text: String?, seq: Int? = nil)
    /// `tool.complete` — a tool call finished
    /// (`{tool_id, name, args, result?, summary?, ...}`).
    case toolComplete(sessionID: String, toolID: String, name: String, summary: String?, seq: Int? = nil)
    /// `background.complete` — a background turn finished (`{task_id, text}`).
    case backgroundComplete(sessionID: String, taskID: String?, text: String?, seq: Int? = nil)
    /// `session.info` — end-of-turn session metadata
    /// (`{model, provider, title?, cwd?, profile_name?, ...}`). R9-T1 adds
    /// the approval-bypass readback fields `yolo` / `approval_mode`
    /// (tui_gateway/server.py:7758 — the same three sources the guard ORs
    /// together, so the toggle reflects effective state, not just the flag).
    case sessionInfo(sessionID: String, model: String?, provider: String?, title: String?, cwd: String?, profileName: String?, yolo: Bool? = nil, approvalMode: String? = nil, seq: Int? = nil)
    /// `approval.request` — a dangerous command is blocked awaiting the
    /// user's decision (R9-T1; tui_gateway/server.py:3102). Not
    /// turn-terminal: the turn keeps streaming while the agent thread parks.
    case approvalRequested(sessionID: String, requestID: String, command: String, detail: String?, choices: [String], seq: Int? = nil)
    /// `session.usage` — a mid-turn usage/context snapshot tick (R9-T3;
    /// tui_gateway/server.py:13133 `_emit("session.usage", sid, {"usage":
    /// _get_usage(agent)})`, ~1s while a turn runs so the context meter
    /// tracks live growth). Not turn-terminal.
    case usageUpdate(sessionID: String, usage: SessionUsageSnapshot, seq: Int? = nil)
    /// `error` — a turn-level error event (`{message, ...}`).
    case error(sessionID: String?, message: String, seq: Int? = nil)
    /// Any event type this client does not model — preserved with its raw
    /// wire type so a newer gateway's event is never dropped (spec §5.5).
    case unknown(sessionID: String?, rawType: String, seq: Int? = nil)
}

extension ConversationEvent {
    /// The session this event belongs to (nil only for session-less events:
    /// a turn-level `error` or an `unknown` event without a session id).
    public var sessionID: String? {
        switch self {
        case .messageStart(let sid, _): return sid
        case .messageDelta(let sid, _, _, _): return sid
        case .messageInterim(let sid, _, _, _): return sid
        case .messageComplete(let sid, _, _, _, _): return sid
        case .thinkingDelta(let sid, _, _): return sid
        case .reasoningDelta(let sid, _, _): return sid
        case .reasoningAvailable(let sid, _, _): return sid
        case .statusUpdate(let sid, _, _, _): return sid
        case .toolStart(let sid, _, _, _, _, _): return sid
        case .toolGenerating(let sid, _, _): return sid
        case .toolProgress(let sid, _, _, _, _): return sid
        case .toolComplete(let sid, _, _, _, _): return sid
        case .backgroundComplete(let sid, _, _, _): return sid
        case .sessionInfo(let sid, _, _, _, _, _, _, _, _): return sid
        case .approvalRequested(let sid, _, _, _, _, _): return sid
        case .usageUpdate(let sid, _, _): return sid
        case .error(let sid, _, _): return sid
        case .unknown(let sid, _, _): return sid
        }
    }

    /// The gateway-stamped monotonic per-session event id (`event_replay.py`
    /// `seq`). Nil for session-less / unstamped fixture events — continuity
    /// tracking ignores those (last-event-id semantics require a stamp).
    public var seq: Int? {
        switch self {
        case .messageStart(_, let seq),
             .messageDelta(_, _, _, let seq),
             .messageInterim(_, _, _, let seq),
             .messageComplete(_, _, _, _, let seq),
             .thinkingDelta(_, _, let seq),
             .reasoningDelta(_, _, let seq),
             .reasoningAvailable(_, _, let seq),
             .statusUpdate(_, _, _, let seq),
             .toolStart(_, _, _, _, _, let seq),
             .toolGenerating(_, _, let seq),
             .toolProgress(_, _, _, _, let seq),
             .toolComplete(_, _, _, _, let seq),
             .backgroundComplete(_, _, _, let seq),
             .sessionInfo(_, _, _, _, _, _, _, _, let seq),
             .approvalRequested(_, _, _, _, _, let seq),
             .usageUpdate(_, _, let seq),
             .error(_, _, let seq),
             .unknown(_, _, let seq):
            return seq
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

/// Continuity verdict for one inbound event against the client's per-session
/// last-applied event id (t_8401d3c3 — client-side no-gap validation).
///
/// The gateway stamps a monotonic per-session `seq` on every event; the
/// conversation layer compares each inbound event's `seq` against its own
/// cursor and classifies the result. This is the CLIENT half of the
/// last-event-id contract: the server half (gap replay from a bounded ring
/// via `session.events.since(last_seen)`) already exists in the gateway.
public enum EventContinuity: Hashable, Sendable, Equatable {
    /// The event's seq is exactly cursor + 1 — perfectly continuous.
    case contiguous
    /// The event's seq ≤ cursor — already applied (replayed overlap or a
    /// duplicate frame); the caller must DROP it (no double render).
    case duplicate
    /// The event's seq > cursor + 1 — at least one event was never applied;
    /// the caller must recover the gap (targeted
    /// `session.events.since(cursor)`) or surface unrecoverable loss.
    case gap(after: Int, before: Int)
    /// The event carries no seq (session-less or unstamped) or no cursor was
    /// recorded yet for the session — continuity is undefined; apply the
    /// event and (when stamped) establish the cursor.
    case unknown

    public var debugDescription: String {
        switch self {
        case .contiguous: return "contiguous"
        case .duplicate: return "duplicate (seq ≤ cursor)"
        case .gap(let after, let before): return "gap: missing \(after + 1)...\(before - 1)"
        case .unknown: return "unknown (unstamped / no cursor)"
        }
    }
}

/// Client-side per-stream event cursor (t_8401d3c3): the last APPLIED event
/// id for one session's stream — the value sent as `last_seen` on
/// subscribe/resume and on reconnect replay.
///
/// Distinct from the transport watermark (highest OBSERVED seq): the cursor
/// advances only when an event is actually applied to the conversation, so a
/// gap detected at apply time is recoverable from exactly the right point
/// even if later events were observed meanwhile.
public struct ConversationEventCursor: Hashable, Sendable, Equatable {
    /// The runtime session id whose stream this cursor tracks.
    public let sessionID: String
    /// The last applied event seq (nil before the first stamped event).
    public let lastEventID: Int?

    public init(sessionID: String, lastEventID: Int?) {
        self.sessionID = sessionID
        self.lastEventID = lastEventID
    }

    /// Classify an inbound event against this cursor.
    public func classify(_ event: ConversationEvent) -> EventContinuity {
        guard let eventSeq = event.seq else { return .unknown }
        guard event.sessionID == sessionID else { return .unknown }
        guard let cursor = lastEventID else { return .unknown }
        if eventSeq <= cursor { return .duplicate }
        if eventSeq == cursor + 1 { return .contiguous }
        return .gap(after: cursor, before: eventSeq)
    }
}
