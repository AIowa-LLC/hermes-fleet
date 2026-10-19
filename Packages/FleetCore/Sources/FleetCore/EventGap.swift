import Foundation

/// A place where the live event stream may have lost events.
///
/// The transport never discards inbound events silently: whenever a bound
/// (frame size, parked-frame budget, subscriber backlog, tracked-session table)
/// forces it to drop something, it publishes a gap so the owner of the affected
/// session can mark its history incomplete and refetch authoritative history.
/// A gap says only "the stream is no longer trustworthy here"; it never carries
/// content.
public struct EventGap: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        /// A subscriber stopped keeping up and its backlog budget was exceeded.
        case subscriberOverflow
        /// Several subscribers together exceeded the aggregate buffer budget.
        case aggregateOverflow
        /// Frames parked during a replay pass exceeded their budget.
        case replayHoldOverflow
        /// An inbound frame was larger than the per-frame limit and was refused.
        case oversizedFrame
        /// A session's replay watermark was evicted from the bounded table.
        case watermarkEvicted
        /// So many gaps were pending that individual ones could not be kept.
        case gapBacklogOverflow
    }

    /// The affected session; `nil` means the affected session is unknown, so
    /// every open session on the gateway must be treated as possibly incomplete.
    public let sessionID: String?
    public let reason: Reason

    public init(sessionID: String?, reason: Reason) {
        self.sessionID = sessionID
        self.reason = reason
    }
}
