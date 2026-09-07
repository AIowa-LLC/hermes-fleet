import Foundation

/// Canonical Bot Chat resolution rules — the exact-title identity contract.
///
/// BINDING (operator correction 2026-09-07, overriding design-doc advisory):
/// a canonical chat is ALWAYS the exact-title `"Bot Chat"` registry row on
/// the bot's OWN gateway/profile, opened by `resolved_id` (fallback `id`).
/// Recency NEVER selects the open target — `last_session` is never opened as
/// a Bot Chat even when it is fresher. The Desktop `botActivitySession`
/// fresher-of rule (data.ts:1411-1420) governs ROSTER PREVIEW display only.
///
/// Fail-closed contract (canonical-chat.ts:206-232, tests
/// canonical-chat-registry.test.ts:248-295):
/// 1. A registry lookup RPC error is an error — NEVER "no chat exists".
/// 2. A SUCCESSFUL EMPTY lookup is unconfirmed absence when the roster
///    already reported a `canonical_session.id` → error, never mint.
/// 3. Only a confirmed registry miss (empty lookup, no prior canonical id)
///    may proceed to safe creation.
public enum CanonicalChatResolution: Hashable, Sendable {
    /// A canonical chat exists — open this exact row.
    case existing(CanonicalSessionRef)
    /// Confirmed registry miss: no row titled "Bot Chat" exists and no prior
    /// canonical id was known. Safe creation (`session.create` hidden +
    /// eager `session.title`) is permitted.
    case confirmedAbsent
    /// Lookup failed or was unconfirmable — the caller MUST surface a
    /// retryable error. Creating or forking a chat in this state is a
    /// contract violation.
    case unconfirmedLookup(String)

    /// Open target when a chat exists (compression tip preferred).
    public var openTargetID: String? {
        if case .existing(let ref) = self { return ref.openID }
        return nil
    }
}

/// Engine applying the fail-closed rules. Pure and testable: the caller
/// supplies the lookup outcome and the roster-known canonical id.
public enum CanonicalChatResolver {
    /// Resolve from a title-exact `session.list` lookup.
    ///
    /// - Parameters:
    ///   - lookupRows: rows returned by `session.list {profile, title:
    ///     "Bot Chat", include_hidden: true}` on the bot's owner gateway.
    ///   - rosterCanonicalID: the `canonical_session.id` the roster
    ///     (profiles.list) reported for this bot, if any.
    ///   - lookupError: the lookup RPC error, if it failed.
    public static func resolve(
        lookupRows: [SessionSummary],
        rosterCanonicalID: String?,
        lookupError: String?
    ) -> CanonicalChatResolution {
        // Rule 1: an RPC failure is never absence (canonical-chat.ts:206-213).
        if let lookupError {
            return .unconfirmedLookup(
                "Could not check the Bot Chat registry: \(lookupError) — not starting a new chat")
        }

        // A matching row: identity is the exact root title lineage.
        // `root_title === "Bot Chat"` on exact-lookup gateways; plain title
        // when no root_title is present (canonical-chat.ts:147-152). A
        // session.list title-exact lookup already scopes to the title, but
        // rows are re-verified here — a mismatched row is not canonical.
        if let row = lookupRows.first(where: { Self.isCanonicalHistoryRow($0) }) {
            // session.list exact-title rows carry `resolved_id` (the
            // compression tip) — re-attached by the networking decoder into
            // `SessionSummary.id` when present. The registry row id is the
            // first-seen row id.
            return .existing(CanonicalSessionRef(
                id: row.id,
                resolvedID: nil, // already the tip when the decoder re-mapped
                rootTitle: BotModeContract.canonicalChatTitle,
                title: row.title,
                preview: row.preview,
                startedAt: row.startedAt,
                lastActive: nil,
                messageCount: row.messageCount
            ))
        }

        // Rule 2: empty SUCCESS is unconfirmed absence when the roster
        // already knows a canonical id (canonical-chat.ts:222-232, #98383).
        if let known = rosterCanonicalID, !known.isEmpty {
            return .unconfirmedLookup(
                "Could not confirm the Bot Chat registry (expected \(known)) — not starting a new chat")
        }

        // Rule 3: confirmed miss.
        return .confirmedAbsent
    }

    static func isCanonicalHistoryRow(_ row: SessionSummary) -> Bool {
        row.title == BotModeContract.canonicalChatTitle
    }
}

/// What a Bot tap must do — the presentation-facing outcome. The open target
/// is ALWAYS the canonical registry row (exact title), never a recency pick.
public enum BotChatOpenPlan: Hashable, Sendable {
    /// Resume the existing canonical chat by its identity.
    case openCanonical(CanonicalSessionRef)
    /// Confirmed absent — create the hidden canonical chat first (safe
    /// creation with eager title + adopt-before-mint semantics), then open.
    case createThenOpen
    /// Retryable failure — show an error; NEVER create or fork.
    case unavailable(String)
}

public enum BotChatPlanner {
    /// Plan a bot tap from the resolution. Enforces the operator-corrected
    /// rule: recency (`latestSession`) never influences the open target.
    public static func plan(from resolution: CanonicalChatResolution) -> BotChatOpenPlan {
        switch resolution {
        case .existing(let ref):
            return .openCanonical(ref)
        case .confirmedAbsent:
            return .createThenOpen
        case .unconfirmedLookup(let message):
            return .unavailable(message)
        }
    }
}
