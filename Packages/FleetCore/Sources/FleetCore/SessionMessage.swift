import Foundation

/// Role of a message in a session transcript, as projected by the gateway's
/// `session.history` → `_history_to_messages` projection (`server.py:9296`).
///
/// The upstream projection emits `user`, `assistant`, `tool`, `system`. Any
/// other value decodes to `.unknown` (spec §5.5: tolerant decoding — an
/// unknown role must never crash the client).
public enum SessionMessageRole: String, Hashable, Sendable, Codable {
    case user
    case assistant
    case tool
    case system

    /// Unrecognized role emitted by a newer gateway; content is preserved but
    /// the client does not attempt to interpret it.
    case unknown

    public init(wire: String) {
        self = SessionMessageRole(rawValue: wire) ?? .unknown
    }

    /// The wire value this role was decoded from (round-trips `.unknown`).
    public var wireValue: String { rawValue }
}

/// One message in a session's history.
///
/// Wire shape (verified in `tui_gateway/server.py` `_history_to_messages`):
/// `{role, text, timestamp?, row_id?, display_kind?, display_metadata?,
/// reasoning?, reasoning_content?, ...}`; tool messages carry
/// `{role: "tool", name, context, args?}`. The projection drops hidden rows
/// and scaffolding server-side; the client stays tolerant of anything else.
public struct SessionMessage: Hashable, Sendable, Identifiable {
    public let role: SessionMessageRole
    /// The rendered text of the message (user prompt / assistant answer /
    /// tool name / system marker). For assistant turns with reasoning only,
    /// this may be empty while `reasoning` carries the thinking content.
    public let text: String
    /// Persisted authoring time (Unix seconds), when the gateway stamped it.
    /// Display-only; never fed back into model context (server.py:9365).
    public let timestamp: Double?
    /// Durable row identity for the persisted turn, when present. This is how
    /// the client can later address a specific message without inventing ids.
    public let rowID: String?
    /// Display-only classification from the gateway (e.g. `skill_invocation`,
    /// timeline markers), preserved verbatim for forward compatibility.
    public let displayKind: String?
    /// Assistant reasoning/thinking content, when the gateway disclosed it.
    public let reasoning: String?
    /// Tool message metadata: the tool's name (tool messages only).
    public let toolName: String?
    /// Tool message context (an 80-char preview of the call), tool only.
    public let toolContext: String?

    public init(
        role: SessionMessageRole,
        text: String,
        timestamp: Double? = nil,
        rowID: String? = nil,
        displayKind: String? = nil,
        reasoning: String? = nil,
        toolName: String? = nil,
        toolContext: String? = nil
    ) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.rowID = rowID
        self.displayKind = displayKind
        self.reasoning = reasoning
        self.toolName = toolName
        self.toolContext = toolContext
    }

    /// Stable identity for list rendering: the durable `row_id` when the
    /// gateway stamped one, else a synthesized role+timestamp+content key
    /// that is stable for a given persisted message. Never derived from
    /// content alone (content can legitimately repeat across messages).
    public var id: String {
        let stamp = timestamp.map { String($0) } ?? "nil"
        return rowID ?? "\(role.rawValue)-\(stamp)-\(text.hashValue)"
    }

    /// Whether the message carries any renderable content: text, reasoning, or
    /// tool metadata (tool rows carry their payload in `toolName`/`toolContext`,
    /// not in `text`).
    public var hasContent: Bool {
        !text.isEmpty
            || !(reasoning?.isEmpty ?? true)
            || !(toolName?.isEmpty ?? true)
            || !(toolContext?.isEmpty ?? true)
    }
}
