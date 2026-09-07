import Foundation

/// What a reconnect + replay pass did, per session (spec §9 Reconnect
/// Contract). Pure domain value (FleetCore) so the UI can render replay
/// fidelity without importing the transport module.
public enum ReplayOutcome: Hashable, Sendable, Equatable {
    /// `session.events.since(lastSeen)` returned newer events and they were
    /// re-applied in order (after deduping the overlap) — `count` events.
    case replayed(sessionID: String, count: Int)
    /// The replay buffer was truncated (events between the watermark and the
    /// ring's oldest retained seq were evicted); the client must refetch
    /// authoritative `session.history` instead of trusting the replay.
    case truncated(sessionID: String)
    /// The gateway's replay_epoch changed (gateway restart / new process).
    /// Stale seq assumptions were discarded and watermarks cleared; the
    /// client rehydrates from server state (spec §9.6).
    case epochChanged(from: String?, to: String?)
    /// The replay RPC for a session failed (best-effort, retried on the next
    /// reconnect per synthesis §10) — the reconnect itself still succeeded.
    case failed(sessionID: String, detail: String)
    /// There were no watermarks to replay (first connect, or nothing seen).
    case nothingToReplay

    /// Human-readable summary for diagnostics (never a promise of fidelity).
    public var debugSummary: String {
        switch self {
        case .replayed(let sid, let count): return "replayed \(count) event(s) for \(sid)"
        case .truncated(let sid): return "replay truncated for \(sid): refetch history"
        case .epochChanged(let from, let to): return "replay epoch changed \(from ?? "nil") → \(to ?? "nil"); rehydrate"
        case .failed(let sid, let detail): return "replay failed for \(sid): \(detail)"
        case .nothingToReplay: return "nothing to replay"
        }
    }
}
