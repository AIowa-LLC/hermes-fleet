import Foundation

/// R10-T2 — Tapback-style message reactions domain.
///
/// Wire shapes verified against the hermes-agent 0.21.0 installed source
/// (`~/.hermes/hermes-agent/tui_gateway/`), 2026-09-04:
/// - `message.react` (methods_session.py:1563-1614): params
///   `{session_id, row_id? | newest_role in {user,assistant}, emoji}` where
///   `emoji` is a non-empty string OR `null` (clear). Optional `author` in
///   `{user, agent}` (server default "user"). Errors: 4023 (row_id or
///   newest_role required), 4024 (emoji empty), 4025 (author invalid),
///   4040 (message not found in this session / no message to react to yet),
///   4001 (runtime session not found — recover via session.resume),
///   5007 (db failure). Result: `{row_id: Int, reactions: [...]}` — the
///   message's FULL reaction list after the write.
/// - Per-author single-reaction semantics live in the DB layer
///   (`set_message_reaction`, hermes_state.py:13008-13040): one reaction per
///   author per message; re-sending the SAME emoji retracts it; a different
///   emoji replaces it; `emoji: null` clears unconditionally.
/// - Read-back: `row_id` is the durable `messages.id` forwarded by
///   `_history_to_messages` (server.py:9921-9927), and rehydrated history
///   rows carry `display_metadata.reactions` — `_rows_to_conversation`
///   (hermes_state.py:14153-14156) forwards the decoded display_metadata,
///   `_history_to_messages` (server.py:9936-9938) forwards it per message.
///   Live in-memory rows never carry reactions (no event pushes them) —
///   reactions only render on rows that came back from durable history.

/// One author's reaction on a message (`{emoji, author, at?}` on the wire).
public struct MessageReaction: Equatable, Hashable, Sendable, Identifiable {
    /// The emoji itself (server-scrubbed of surrogates).
    public let emoji: String
    /// Reaction author: "user" or "agent" (wire default "user" when absent).
    public let author: String
    /// Display-only Unix-seconds stamp (server `time.time()`), when present.
    public let at: Double?

    public init(emoji: String, author: String = "user", at: Double? = nil) {
        self.emoji = emoji
        self.author = author
        self.at = at
    }

    public var id: String { "\(author):\(emoji)" }
}

/// The result of a `message.react` call: the durable row the write landed on
/// plus the message's full post-write reaction list (server truth).
public struct MessageReactionResult: Equatable, Sendable {
    public let rowID: String
    public let reactions: [MessageReaction]

    public init(rowID: String, reactions: [MessageReaction]) {
        self.rowID = rowID
        self.reactions = reactions
    }
}

/// Which message a reaction addresses. Durable rows (rehydrated history with
/// a `row_id`) use `.durable`; a live row the user just watched stream in has
/// no durable id yet — the gateway resolves `newest_role` to the newest
/// persisted row of that role (methods_session.py:1576-1579).
public enum MessageReactionTarget: Equatable, Sendable {
    case durable(rowID: String)
    case newest(role: String)

    /// The durable `messages.id`, when this target addresses one.
    public var rowID: String? {
        if case .durable(let rowID) = self { return rowID }
        return nil
    }

    /// The `newest_role` value ("user" | "assistant"), when live.
    public var newestRole: String? {
        if case .newest(let role) = self { return role }
        return nil
    }

    /// Build a live target; nil unless the role is one the gateway accepts
    /// (`newest_role in {user, assistant}`, methods_session.py:1577).
    /// A failable init — NOT a static `newest(role:)` builder, which would
    /// shadow the enum case factory of the same signature and misbind at
    /// runtime (observed as SIGSEGV in the test runner).
    public init?(liveRole role: String) {
        guard role == "user" || role == "assistant" else { return nil }
        self = .newest(role: role)
    }
}

/// A message's reaction list plus the value-semantics merge used for the
/// optimistic update (server truth arrives in `MessageReactionResult`).
public struct MessageReactionsSnapshot: Equatable, Sendable {
    public let reactions: [MessageReaction]

    public init(reactions: [MessageReaction]) {
        self.reactions = reactions
    }

    public static let empty = MessageReactionsSnapshot(reactions: [])

    /// The local user's own reaction emoji, when they have one.
    public var ownEmoji: String? {
        reactions.first { $0.author == "user" }?.emoji
    }

    /// The optimistic merge for sending `emoji`: the user's own reaction
    /// becomes `emoji` (replacing any previous one — the per-author
    /// single-reaction semantics mirrored client-side), everyone else's
    /// reactions survive. Value semantics: the receiver is untouched.
    public func applyingOwnReaction(_ emoji: String) -> MessageReactionsSnapshot {
        var kept = reactions.filter { $0.author != "user" }
        kept.append(MessageReaction(emoji: emoji, author: "user"))
        return MessageReactionsSnapshot(reactions: kept)
    }

    /// The optimistic merge for clearing (`emoji: null`).
    public func clearingOwnReaction() -> MessageReactionsSnapshot {
        MessageReactionsSnapshot(reactions: reactions.filter { $0.author != "user" })
    }

    /// Adopt server truth (the post-write reaction list).
    public init(_ result: MessageReactionResult) {
        self.reactions = result.reactions
    }
}

/// The small Tapback-style palette offered on long-press.
public struct MessageReactionPalette: Sendable {
    /// Ordered palette (👍 first — the primary affirmative).
    public let emojis: [String]

    public init(emojis: [String]) {
        self.emojis = emojis
    }

    public static let standard = MessageReactionPalette(
        emojis: ["👍", "❤️", "😂", "😮", "🎉", "👀"])
}
