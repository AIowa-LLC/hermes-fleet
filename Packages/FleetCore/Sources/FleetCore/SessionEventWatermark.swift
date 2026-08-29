import Foundation

/// Per-session sequence watermark: the highest event `seq` this client has
/// observed for a session, persisted across disconnects so a reconnecting
/// client can request `session.events.since(lastSeen)` (spec §9).
///
/// Pure domain value (FleetCore) so the UI/replay seam can render or persist
/// watermarks without importing the transport module. Watermarks are
/// server-authoritative derived state: they never invent an event that the
/// client did not actually observe (spec §9 "the client must not invent
/// missing events").
public struct SessionEventWatermark: Hashable, Sendable, Equatable {
    /// The runtime session id these events belong to.
    public let sessionID: String
    /// The highest `seq` observed for that session (0 = none observed yet).
    public let lastSeenSeq: Int

    public init(sessionID: String, lastSeenSeq: Int) {
        self.sessionID = sessionID
        self.lastSeenSeq = lastSeenSeq
    }
}
