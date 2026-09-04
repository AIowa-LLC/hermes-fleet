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
    /// R10-T2: reactions this message carries, when the wire disclosed
    /// them. Durable history rows carry `display_metadata.reactions`
    /// (`_rows_to_conversation` hermes_state.py:14153 →
    /// `_history_to_messages` server.py:9936); live streamed rows never do
    /// (no event pushes reactions). Nil = not disclosed; empty = disclosed
    /// as none.
    public let reactions: [MessageReaction]?
    /// Launch-stable client identity (B1): a UUID minted at message
    /// construction when the gateway did not stamp a durable `row_id`, and
    /// persisted through the FleetPersistence seam so the same stored message
    /// reloads with the same id across app launches. Never derived from a
    /// randomized hash. Excluded from value equality: two messages with
    /// identical content are equal even when each carries its own minted id.
    public let clientID: String?

    public init(
        role: SessionMessageRole,
        text: String,
        timestamp: Double? = nil,
        rowID: String? = nil,
        displayKind: String? = nil,
        reasoning: String? = nil,
        toolName: String? = nil,
        toolContext: String? = nil,
        reactions: [MessageReaction]? = nil,
        clientID: String? = nil
    ) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.rowID = rowID
        self.displayKind = displayKind
        self.reasoning = reasoning
        self.toolName = toolName
        self.toolContext = toolContext
        self.reactions = reactions
        // Mint a launch-stable UUID at construction whenever there is no
        // durable row_id and the caller (e.g. the persistence seam restoring a
        // stored row) did not supply an existing one. This is the ONLY id
        // source that never depends on Swift's randomized per-launch hashing.
        self.clientID = clientID ?? (rowID == nil ? UUID().uuidString : nil)
    }

    /// Stable identity for list rendering: the durable `row_id` when the
    /// gateway stamped one, else the launch-stable `clientID` minted at
    /// construction (B1). The synthesized path is never derived from a
    /// randomized hash, so a persisted message keeps the same id across
    /// restarts and duplicate-text messages keep distinct ids.
    public var id: String {
        if let rowID { return rowID }
        if let clientID { return clientID }
        // Unreachable in practice: init mints a clientID whenever rowID is
        // nil. This defensive fallback stays deterministic (no hashValue).
        let stamp = timestamp.map { String($0) } ?? "nil"
        return "\(role.rawValue)-\(stamp)"
    }

    /// Value equality is CONTENT equality (spec §5.5): the minted `clientID`
    /// is identity, not content, so it is excluded from Equatable/Hashable.
    public static func == (lhs: SessionMessage, rhs: SessionMessage) -> Bool {
        lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.timestamp == rhs.timestamp
            && lhs.rowID == rhs.rowID
            && lhs.displayKind == rhs.displayKind
            && lhs.reasoning == rhs.reasoning
            && lhs.toolName == rhs.toolName
            && lhs.toolContext == rhs.toolContext
            && lhs.reactions == rhs.reactions
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(role)
        hasher.combine(text)
        hasher.combine(timestamp)
        hasher.combine(rowID)
        hasher.combine(displayKind)
        hasher.combine(reasoning)
        hasher.combine(toolName)
        hasher.combine(toolContext)
        hasher.combine(reactions)
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
