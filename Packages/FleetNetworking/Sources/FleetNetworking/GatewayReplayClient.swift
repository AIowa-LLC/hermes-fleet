import Foundation
import FleetCore

/// A batch of events returned by `session.events.since`.
///
/// Wire contract (verified in `tui_gateway/methods_session.py:3642` +
/// `event_replay.py`):
/// `{"events": [bare_event...], "latest_seq": N, "truncated": bool,
/// "count": N, "epoch": "..."}` where each bare event is the frame's `params`
/// dict (`{type, session_id, seq, payload}`) — decoded via
/// `GatewayEvent(replayParams:)`.
public struct ReplayBatch: Sendable, Hashable {
    /// The session these events belong to (echoed from the caller's request).
    public let sessionID: String
    /// Replayed events in ascending seq order (seq > last_seen by contract).
    public let events: [GatewayEvent]
    /// The gateway's current highest stamped seq for this session.
    public let latestSeq: Int
    /// True when the ring no longer holds everything after `last_seen`
    /// (a gap was evicted) — the client MUST refetch authoritative
    /// `session.history` instead of trusting the replay (spec §9.5).
    public let truncated: Bool
    /// Number of events returned.
    public let count: Int
    /// The server-process replay epoch at response time (restart detection).
    public let epoch: String?

    public init(
        sessionID: String,
        events: [GatewayEvent],
        latestSeq: Int,
        truncated: Bool,
        count: Int,
        epoch: String?
    ) {
        self.sessionID = sessionID
        self.events = events
        self.latestSeq = latestSeq
        self.truncated = truncated
        self.count = count
        self.epoch = epoch
    }
}

/// Concrete client for the `session.events.since` replay RPC (P4 — M6).
///
/// The replay engine issues this after a reconnect to fetch every event newer
/// than a session's watermark. This type sends ONLY the read-only replay
/// method — it contains no mutating call (spec §5.4; replay observes, it never
/// claims ownership of a session's live transport).
public struct GatewayReplayClient {
    /// The gateway this client is bound to.
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    /// Fetch events newer than `lastSeen` for a session.
    ///
    /// - Parameters:
    ///   - sessionID: the session whose events to replay.
    ///   - lastSeen: the client's last observed seq (its watermark). The
    ///     gateway returns every buffered event with seq > last_seen.
    /// - Returns: the replayed batch (events in order, latest_seq, truncated,
    ///   count, epoch).
    public func fetchEventsSince(sessionID: String, lastSeen: Int) async throws -> ReplayBatch {
        guard case .connected = transport.state else { throw ReplayError.notConnected }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "last_seen": .number(Double(lastSeen)),
        ])
        do {
            let result = try await transport.request(method: "session.events.since", params: params)
            return try Self.decode(sessionID: sessionID, result)
        } catch let error as ReplayError {
            // Decode-level failures pass through unchanged.
            throw error
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ReplayError.rpcFailed(String(describing: error))
        }
    }

    // MARK: decoding (wire → domain)

    /// `session.events.since` → `{events: [...], latest_seq, truncated, count,
    /// epoch}` (methods_session.py:3659-3669). Tolerant: unknown/missing
    /// members default rather than failing the whole batch. Public so the
    /// replay engine and wire-shape tests share the one decoder.
    public static func decode(sessionID: String, _ result: JSONValue) throws -> ReplayBatch {
        let events = result["events"]?.arrayValue?
            .compactMap(GatewayEvent.init(replayParams:)) ?? []
        let latestSeq = result["latest_seq"]?.numberValue.map(Int.init) ?? 0
        let truncated = result["truncated"]?.boolValue ?? false
        let count = result["count"]?.numberValue.map(Int.init) ?? events.count
        let epoch = result["epoch"]?.stringValue
        return ReplayBatch(
            sessionID: sessionID,
            events: events,
            latestSeq: latestSeq,
            truncated: truncated,
            count: count,
            epoch: epoch
        )
    }

    /// Map a transport-level failure onto the replay error vocabulary (the
    /// seam stays free of `TransportError`).
    static func mapTransportError(_ error: TransportError) -> ReplayError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(String(describing: error))
        }
    }
}
