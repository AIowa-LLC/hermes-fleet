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
    /// The result's server→client request snapshot, preserved verbatim for
    /// callers that need it. The transport also admits these requests before
    /// returning the RPC result so replay keeps the existing #77 behavior.
    public let openRequests: JSONValue?

    public init(
        sessionID: String,
        events: [GatewayEvent],
        latestSeq: Int,
        truncated: Bool,
        count: Int,
        epoch: String?,
        openRequests: JSONValue? = nil
    ) {
        self.sessionID = sessionID
        self.events = events
        self.latestSeq = latestSeq
        self.truncated = truncated
        self.count = count
        self.epoch = epoch
        self.openRequests = openRequests
    }

    /// Validate the decoded batch against the request that produced it.
    /// Structural validation happens while decoding so malformed wire events
    /// can never be compacted away before this check.
    public func validate(sessionID expectedSessionID: String, lastSeen: Int) throws {
        guard lastSeen >= 0 else {
            throw ReplayError.malformedPayload("last_seen must be non-negative")
        }
        guard sessionID == expectedSessionID else {
            throw ReplayError.malformedPayload("batch session does not match the request")
        }
        guard latestSeq >= 0, count >= 0 else {
            throw ReplayError.malformedPayload("latest_seq and count must be non-negative")
        }
        guard latestSeq >= lastSeen else {
            throw ReplayError.malformedPayload("latest_seq is below last_seen")
        }
        if !truncated, count != events.count {
            throw ReplayError.malformedPayload("count does not match events length")
        }

        var previousSeq = lastSeen
        for event in events {
            guard event.sessionID == expectedSessionID else {
                throw ReplayError.malformedPayload("event session_id does not match the request")
            }
            guard let seq = event.seq, seq >= 0 else {
                throw ReplayError.malformedPayload("event seq must be a non-negative integer")
            }
            guard seq > previousSeq else {
                throw ReplayError.malformedPayload("event seq values must increase above last_seen")
            }
            previousSeq = seq
        }
        if let maxSeq = events.last?.seq, latestSeq < maxSeq {
            throw ReplayError.malformedPayload("latest_seq is below the highest event seq")
        }
        if !truncated, latestSeq > lastSeen, events.last?.seq != latestSeq {
            throw ReplayError.malformedPayload("complete batch does not reach latest_seq")
        }
    }
}

/// Concrete client for the `session.events.since` replay RPC (P4 — M6).
///
/// The replay engine issues this after a reconnect to fetch every event newer
/// than a session's watermark. This type sends ONLY the read-only replay
/// method — it contains no mutating call (spec §5.4; replay observes, it never
/// claims ownership of a session's live transport).
public struct GatewayReplayClient: Sendable {
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
        guard lastSeen >= 0 else {
            throw ReplayError.malformedPayload("last_seen must be non-negative")
        }
        guard case .connected = transport.state else { throw ReplayError.notConnected }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "last_seen": .number(Double(lastSeen)),
        ])
        do {
            // Idempotent read: retried under the bounded read policy.
            let result = try await transport.readRequest(method: "session.events.since", params: params)
            return try Self.decode(sessionID: sessionID, result, lastSeen: lastSeen)
        } catch let error as ReplayError {
            // Decode-level failures pass through unchanged.
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as JSONRPCError {
            throw error
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ReplayError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    // MARK: decoding (wire → domain)

    /// `session.events.since` → `{events: [...], latest_seq, truncated, count,
    /// epoch}` (methods_session.py:3659-3669). Every required envelope field
    /// and event is validated; malformed data is rejected rather than
    /// defaulted or compacted. `open_requests` is retained unchanged.
    public static func decode(
        sessionID: String,
        _ result: JSONValue,
        lastSeen: Int = 0
    ) throws -> ReplayBatch {
        guard lastSeen >= 0 else {
            throw ReplayError.malformedPayload("last_seen must be non-negative")
        }
        guard let rawEvents = result["events"]?.arrayValue else {
            throw ReplayError.malformedPayload("events must be an array")
        }
        guard let latestSeq = strictInteger(result["latest_seq"]) else {
            throw ReplayError.malformedPayload("latest_seq must be an integer")
        }
        guard let truncated = result["truncated"]?.boolValue else {
            throw ReplayError.malformedPayload("truncated must be a boolean")
        }
        guard let count = strictInteger(result["count"]) else {
            throw ReplayError.malformedPayload("count must be an integer")
        }

        var events: [GatewayEvent] = []
        events.reserveCapacity(rawEvents.count)
        for rawEvent in rawEvents {
            guard let object = rawEvent.objectValue,
                  let type = object["type"]?.stringValue, !type.isEmpty,
                  let eventSessionID = object["session_id"]?.stringValue,
                  eventSessionID == sessionID,
                  let seq = strictInteger(object["seq"]), seq >= 0,
                  let event = GatewayEvent(replayParams: rawEvent)
            else {
                throw ReplayError.malformedPayload("event is missing a valid type, session_id, or seq")
            }
            events.append(event)
        }

        let epoch: String?
        if let rawEpoch = result["epoch"], rawEpoch != .null {
            guard let value = rawEpoch.stringValue else {
                throw ReplayError.malformedPayload("epoch must be a string when present")
            }
            epoch = value
        } else {
            epoch = nil
        }

        let batch = ReplayBatch(
            sessionID: sessionID,
            events: events,
            latestSeq: latestSeq,
            truncated: truncated,
            count: count,
            epoch: epoch,
            openRequests: result["open_requests"]
        )
        try batch.validate(sessionID: sessionID, lastSeen: lastSeen)
        return batch
    }

    private static func strictInteger(_ value: JSONValue?) -> Int? {
        guard let value, let number = value.numberValue,
              number.rounded(.towardZero) == number,
              let integer = value.intValue else { return nil }
        return integer
    }

    /// Map a transport-level failure onto the replay error vocabulary (the
    /// seam stays free of `TransportError`).
    static func mapTransportError(_ error: TransportError) -> ReplayError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout(let method):
            return .rpcFailed(GatewayRequestCatalog.timeoutMessage(forMethod: method))
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(Redaction.safeErrorDescription(error))
        }
    }
}
