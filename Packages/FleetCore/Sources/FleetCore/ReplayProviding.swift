import Foundation

/// The reconnect/replay seam that keeps SwiftUI free of JSON-RPC / WebSocket
/// plumbing (mirrors `SessionHistoryProviding` / `ConversationProviding` /
/// `GatewayConnectivityProviding`).
///
/// P4 scope (spec §9 Reconnect Contract + synthesis §10 state machine): after
/// a reconnect the client compares the gateway's replay_epoch, requests events
/// newer than each session watermark via `session.events.since`, deduplicates
/// the overlap, applies in order, refetches `session.history` when replay is
/// truncated, and clears stale watermarks when the epoch changed. This seam
/// exposes that as an explicit, observable operation — the UI never performs
/// the JSON-RPC itself (M0 guard).
public protocol ReplayProviding: Sendable {
    /// The gateway this replay engine is bound to.
    var gatewayID: GatewayID { get }

    /// Current per-session seq watermarks (highest observed seq per session).
    /// Persist across disconnects so replay resumes exactly where it stopped.
    func watermarks() async -> [SessionEventWatermark]

    /// Perform the reconnect + replay protocol against the currently
    /// connected transport (assumes `connect()` already succeeded on the
    /// reconnected socket):
    /// 1. compare the adopted gateway replay_epoch vs the stored epoch;
    /// 2. epoch changed → clear watermarks, adopt the new epoch, return
    ///    `.epochChanged` (client rehydrates from server state);
    /// 3. epoch matches → for each watermarked session call
    ///    `session.events.since(lastSeen)`, dedupe overlap, apply in order,
    ///    and if the buffer was truncated refetch authoritative
    ///    `session.history`.
    ///
    /// Returns the outcome per affected session (empty when nothing to do).
    func replayAfterReconnect() async throws -> [ReplayOutcome]
}

/// Errors the replay seam surfaces (self-contained; the seam stays free of
/// `TransportError`).
public enum ReplayError: Error, Sendable, Equatable, LocalizedError {
    /// The transport is not connected, so no replay can run.
    case notConnected
    /// `session.events.since` returned a malformed batch.
    case malformedPayload(String)
    /// The replay RPC failed at the transport level.
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "gateway not connected; cannot replay"
        case .malformedPayload(let s): return "malformed replay payload: \(s)"
        case .rpcFailed(let s): return "replay RPC failed: \(s)"
        }
    }
}
