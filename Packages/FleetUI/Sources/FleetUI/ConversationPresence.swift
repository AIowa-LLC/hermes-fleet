import Foundation

/// What the 1:1 conversation shows for the in-flight turn (GitHub #107).
///
/// - `idle`: no turn in flight; no presence row.
/// - `thinking`: a turn is running and nothing has been produced yet (no
///   assistant text, no tool activity) — the "Thinking" placeholder row.
/// - `working`: a turn is running, tool activity started, no text yet.
/// - `streaming`: assistant text for this turn has started arriving.
enum ConversationPresenceState: Equatable, Sendable {
    case idle
    case thinking
    case working
    case streaming
}

/// Pure presence decision. Kept free of view and model types so it can be
/// unit-tested directly.
enum ConversationPresence {
    /// Elapsed seconds at which the thinking label starts showing the clock.
    static let elapsedThreshold = 3

    static func state(
        isTurnActive: Bool,
        hasAssistantTextThisTurn: Bool,
        hasToolActivity: Bool
    ) -> ConversationPresenceState {
        guard isTurnActive else { return .idle }
        if hasAssistantTextThisTurn { return .streaming }
        return hasToolActivity ? .working : .thinking
    }

    /// The thinking label shows the elapsed clock only once it reaches 3s, so
    /// a fast turn does not flash a timer.
    static func showsElapsed(_ seconds: Int) -> Bool {
        seconds >= elapsedThreshold
    }
}

extension ConversationViewModel {
    /// Presence derived from the existing transcript and turn clock. "This
    /// turn" is the rows after the most recent user row.
    var conversationPresence: ConversationPresenceState {
        var hasText = false
        var hasTool = false
        for row in transcript.reversed() {
            if row.kind == .user { break }
            if row.kind == .assistant, !row.text.isEmpty, !row.isFailed { hasText = true }
            if row.kind == .tool { hasTool = true }
        }
        return ConversationPresence.state(
            isTurnActive: isWorking,
            hasAssistantTextThisTurn: hasText,
            hasToolActivity: hasTool
        )
    }
}
