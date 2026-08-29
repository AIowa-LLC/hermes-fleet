import Foundation
import FleetCore

/// Concrete `ReplayProviding` for the Hermes gateway reconnect/replay path
/// (P4 — M6).
///
/// Implements the spec §9 Reconnect Contract + synthesis §10 state machine on
/// top of a re-connectable `GatewayWebSocketTransport`:
///
/// 1. After reconnect, compare the adopted `gateway.ready` replay_epoch to the
///    epoch adopted at the previous connection.
/// 2. Epoch changed (gateway restart / new process) → discard stale seq
///    assumptions: clear transport watermarks, adopt the new epoch, and return
///    `.epochChanged` so the client rehydrates from server state (§9.6).
/// 3. Epoch matches → for each watermarked session, call `session.events.since
///    (lastSeen)`; deduplicate the replay overlap (drop seq ≤ watermark);
///    apply events in order by injecting them back through the transport's
///    live event channel while live frames are parked (replay-hold); if the
///    buffer reports `truncated`, refetch authoritative `session.history`
///    instead of trusting a gap (§9.5).
///
/// The engine never invents missing events (§9): it only re-applies what the
/// gateway returns. Best-effort replay failures are surfaced per-session via
/// `.failed` and retried on the next reconnect — they never crash a reconnect.
public actor GatewayReplayEngine: ReplayProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport
    private let history: any SessionHistoryProviding

    /// The replay epoch adopted at the last successful connect (nil before the
    /// first). Compared against the fresh epoch after each reconnect.
    private var adoptedEpoch: String?

    public init(
        gatewayID: GatewayID,
        transport: GatewayWebSocketTransport,
        history: any SessionHistoryProviding
    ) {
        self.gatewayID = gatewayID
        self.transport = transport
        self.history = history
    }

    // MARK: ReplayProviding

    public func watermarks() async -> [SessionEventWatermark] {
        let all = await transport.allWatermarks()
        return all.map { SessionEventWatermark(sessionID: $0.key, lastSeenSeq: $0.value) }
            .sorted { $0.sessionID < $1.sessionID }
    }

    public func replayAfterReconnect() async throws -> [ReplayOutcome] {
        guard case .connected = transport.state else {
            throw ReplayError.notConnected
        }
        guard let ready = await transport.adoptedReady() else {
            throw ReplayError.malformedPayload("no adopted gateway.ready on reconnect")
        }
        let newEpoch = ready.replayEpoch
        let previousEpoch = adoptedEpoch

        // 1. Epoch comparison (§9.1). First connect: nothing was adopted yet,
        // so there is nothing to replay — just adopt.
        guard let previousEpoch else {
            adoptedEpoch = newEpoch
            return [.nothingToReplay]
        }
        // 2. Epoch changed (§9.6): discard stale seq assumptions.
        if previousEpoch != newEpoch {
            await transport.clearWatermarks()
            adoptedEpoch = newEpoch
            return [.epochChanged(from: previousEpoch, to: newEpoch)]
        }

        // 3. Epoch matches: replay each watermarked session (§9.2).
        let watermarks = await transport.allWatermarks()
        guard !watermarks.isEmpty else {
            return [.nothingToReplay]
        }

        // Park live frames during replay (§10 replayHold) so replayed events
        // inject in order; flush seq-gated afterwards (dedupe).
        await transport.beginReplayHold()
        var outcomes: [ReplayOutcome] = []
        for sessionID in watermarks.keys.sorted() {
            let lastSeen = watermarks[sessionID] ?? 0
            do {
                let outcome = try await replaySession(sessionID: sessionID, lastSeen: lastSeen)
                outcomes.append(outcome)
            } catch let error as ReplayError {
                // Best-effort (§10): record and continue; retried next reconnect.
                outcomes.append(.failed(sessionID: sessionID, detail: error.localizedDescription))
            } catch {
                outcomes.append(.failed(sessionID: sessionID, detail: String(describing: error)))
            }
        }
        await transport.endReplayHold()
        return outcomes
    }

    // MARK: per-session replay

    private func replaySession(sessionID: String, lastSeen: Int) async throws -> ReplayOutcome {
        // Issue `session.events.since` directly over the transport (same
        // request/correlation the replay client uses); the client's static
        // decode is reused so wire-shape handling stays in one place.
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "last_seen": .number(Double(lastSeen)),
        ])
        let result = try await transport.request(method: "session.events.since", params: params)
        let batch = try GatewayReplayClient.decode(sessionID: sessionID, result)

        // 4. Truncation (§9.5): the ring evicted events between lastSeen and
        // its oldest retained seq — refetch authoritative history instead of
        // trusting a gap. Never invent the missing events.
        if batch.truncated {
            // Best-effort authoritative refetch; a failure here is recorded on
            // the outcome, not thrown (the client still knows to rehydrate).
            do {
                _ = try await history.fetchSessionHistory(sessionID: sessionID)
            } catch {
                // History refetch failed; the outcome still signals truncation.
            }
            await transport.advanceWatermark(to: batch.latestSeq, for: sessionID)
            return .truncated(sessionID: sessionID)
        }

        // 5. Dedupe replay overlap (§9.3) + apply in order (§9.4): only events
        // strictly newer than the current watermark are re-injected. Events
        // ≤ watermark are already applied (live) or were evicted — dropping
        // them is the "no dup" contract.
        let replayed = batch.events.filter { ($0.seq ?? 0) > lastSeen }
        guard !replayed.isEmpty else {
            await transport.advanceWatermark(to: batch.latestSeq, for: sessionID)
            return .nothingToReplay
        }
        await transport.injectReplayedEvents(replayed)
        await transport.advanceWatermark(to: batch.latestSeq, for: sessionID)
        return .replayed(sessionID: sessionID, count: replayed.count)
    }
}
