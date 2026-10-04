import Foundation
import os
import FleetCore

/// Errors thrown by `GatewayWebSocketTransport.connect()` / during the
/// connection lifecycle.
public enum TransportError: Error, Sendable, Equatable, LocalizedError {
    case invalidState(String)
    case ticketMintFailed(String)
    case unableToBuildURL
    case connectTimeout
    case readyTimeout
    case requestTimeout
    case connectionClosed(DisconnectReason)
    case transportFailure(String)
    /// Authentication (ticket mint / loopback token lookup) failed before the
    /// socket opened. Never carries secret material (spec §29).
    case authenticationFailed(String)
    /// F1: the auth REST surface answered this HTTP status (401/403 → the
    /// credential was rejected; other statuses → wrong surface/port).
    case authSurfaceStatus(Int)
    /// P0-9: the auth REST surface rejected the request and NAMED its cause
    /// in the JSON body (the tunnel's 401 `{"reason":"no_cookie"}` — a
    /// token-strategy mint against a cookie-only gateway). Carries the
    /// server-echoed classification word, never secret material.
    case authStrategyRejected(AuthRejectionReason)

    public var errorDescription: String? {
        switch self {
        case .invalidState(let s): return "invalid transport state: \(s)"
        case .ticketMintFailed(let s): return "ticket mint failed: \(s)"
        case .unableToBuildURL: return "unable to build WebSocket URL"
        case .connectTimeout: return "WebSocket connect timed out"
        case .readyTimeout: return "gateway.ready handshake timed out"
        case .requestTimeout: return "request timed out"
        case .connectionClosed(let r): return "connection closed: \(r.debugDescription)"
        case .transportFailure(let s): return "transport failure: \(s)"
        case .authenticationFailed(let s): return "authentication failed: \(s)"
        case .authSurfaceStatus(let code): return "auth endpoint returned HTTP \(code)"
        case .authStrategyRejected(let reason): return "auth rejected: \(reason.rawValue)"
        }
    }
}

/// Concrete `HermesTransport` for the Hermes gateway `/api/ws` WebSocket
/// JSON-RPC seam.
///
/// Lifecycle: mint ticket → open socket → receive `gateway.ready` → adopt
/// heartbeat flag + replay_epoch → run 15s ping / 45s inbound-deadline
/// heartbeat while open → map close codes to `DisconnectReason` on teardown.
///
/// P4 (M6) — reconnect/replay: the transport is RE-CONNECTABLE. `connect()`
/// may be called again after a clean `disconnect()` (state `.closed`) or an
/// abnormal close (state `.error`) — this fixes the M1 P4 residual where a
/// reconnect after clean disconnect failed readyTimeout because the ready
/// handshake channel was single-shot (finished at teardown). Per-session seq
/// watermarks are tracked from every observed event and persisted across
/// disconnect, so a reconnecting client can request `session.events.since`
/// and replayed events can be injected back through the live event channel.
/// Inbound live frames arriving during a replay pass are parked (replay-hold)
/// and flushed seq-gated so replay never duplicates or reorders (spec §9/§10).
public actor GatewayWebSocketTransport: HermesTransport {
    // MARK: configuration
    private let baseURL: URL
    private let authentication: any AuthenticationProviding
    private let sessionFactory: any WebSocketSessionFactory
    private let config: TransportConfiguration

    // MARK: observable state (nonisolated via lock box)
    private let stateBox: TransportStateBox
    public nonisolated var state: TransportState { stateBox.current }

    /// t_a07ca37e: heartbeat-freshness snapshot — when the last VALID
    /// inbound frame (heartbeat pong or payload; junk never refreshes it,
    /// P1-4) arrived. Nil when no connection has ever been established.
    /// Consumers derive the tier at read time, so this never goes stale.
    public nonisolated var liveness: ConnectionLivenessSnapshot? {
        lastFrameBox.read()
    }

    // MARK: lifecycle state (actor-isolated)
    private var connectionState: ConnectionState = .idle
    private var connectAttemptID = 0
    private var connectWaiters: [Int: [CheckedContinuation<Void, any Error>]] = [:]
    private var session: (any WebSocketSession)?
    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastInbound: ContinuousClock.Instant
    /// t_a07ca37e: lock-boxed mirror of `lastInbound` so a `nonisolated`
    /// `liveness` accessor (consumed by the view model's status watcher on
    /// the main actor) can read the last-frame instant without hopping to
    /// the transport actor. Async-safe scoped locking, matching
    /// `TransportStateBox`.
    private let lastFrameBox: TransportLastFrameBox
    /// t_a07ca37e: number of tool calls started but not yet completed on
    /// this connection — a mid-flight tool call extends the reconnect window
    /// (18s → 25s) because the gateway legitimately stays silent while a
    /// tool executes server-side (Hermex #227 runningToolReconnectInterval).
    private var inFlightToolCalls = 0
    /// P1-4: consecutive junk frames (binary, or text failing JSON-RPC decode).
    /// Reset on any valid protocol frame; teardown when the bounded limit is
    /// exceeded. Junk NEVER refreshes `lastInbound`.
    private var malformedFrameCount = 0
    private var readyPayload: GatewayEvent.ReadyPayload?
    private var nextHeartbeatID: Int = 0

    /// The classified reason the last connection ended (nil until first close).
    /// P4 (M6): surfaced so the reconnect policy (4401 → re-auth, never silent
    /// retry) can be applied by the composition root without re-deriving it.
    public private(set) var lastDisconnectReason: DisconnectReason?

    // MARK: reconnect/replay state (P4 — M6)
    /// Per-session seq watermarks: the highest `seq` this transport has
    /// observed per session id, persisted across disconnect so a reconnecting
    /// client can request `session.events.since(lastSeen)` (spec §9). Cleared
    /// only on replay-epoch change (gateway restart) — never invented.
    private var sessionWatermarks: [String: Int] = [:]

    /// Replay-hold (spec §9/§10): while true, inbound event frames for
    /// watermarked sessions are parked instead of forwarded, so a replayed
    /// `session.events.since` batch can be injected in order before the live
    /// frames resume. On flush, held frames with seq ≤ watermark are dropped
    /// (dedupe); the rest are forwarded in order.
    private var replayHoldActive = false
    private var replayHoldBuffer: [GatewayEvent] = []
    /// Sessions that lost parked frames to the hold cap: their next replay must
    /// rehydrate from authoritative history (never trust a silent gap).
    private var replayHoldOverflowSessions: Set<String> = []
    private var replayHoldBytes = 0
    /// Sessions that may have lost events while the connection stayed up
    /// (evicted watermark, refused frame). Reported by the next replay pass as
    /// needing authoritative history; `incompleteAll` collapses the set when
    /// the peer produced more distinct sessions than we will track.
    private var incompleteSessions: Set<String> = []
    private var incompleteAll = false
    /// LRU clock for the bounded watermark table.
    private var watermarkTouch: [String: UInt64] = [:]
    private var touchClock: UInt64 = 0

    /// Hard bounds so a hostile or buggy gateway cannot grow client work or
    /// memory without limit with individually valid frames.
    /// - Frames parked while a replay pass is in flight.
    public static let maxReplayHoldEvents = GatewayEventBudget.maxReplayHoldEvents
    public static let maxReplayHoldBytes = GatewayEventBudget.maxReplayHoldBytes
    /// - Distinct sessions with a tracked watermark.
    public static let maxTrackedSessions = GatewayEventBudget.maxTrackedSessions
    /// - Backlog a single event subscriber may accumulate before the oldest
    ///   undelivered events are discarded.
    public static let maxSubscriberBacklog = GatewayEventBudget.maxSubscriberBacklog

    // MARK: RPC correlation (M2)
    /// Requests awaiting a correlated response, keyed by request id.
    /// The receive loop resumes the matching continuation on `.response` /
    /// `.error`; teardown fails every pending request so callers never hang.
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextRequestID: Int = 0

    /// Ready-handshake channel: the receive loop yields `gateway.ready`
    /// payloads here; `waitForReady()` consumes the first one with a timeout.
    ///
    /// P4 (M6): this channel is RE-CREATED on every `connect()` — the M1 P4
    /// residual was that it was single-shot (finished at first teardown), so a
    /// reconnect iterated a finished stream and failed readyTimeout.
    private var readyEvents: AsyncStream<GatewayEvent.ReadyPayload>
    private var readyContinuation: AsyncStream<GatewayEvent.ReadyPayload>.Continuation

    /// Inbound event fan-out (M5, revised P0-7): every decoded `GatewayEvent`
    /// is delivered to every live subscriber so the conversation client can
    /// attach a FRESH event pipe each time a conversation screen is entered.
    /// The previous single-subscriber channel died with the first consumer's
    /// task (the view model is destroyed on pop), leaving a re-entered
    /// conversation silently unsubscribed — replies streamed but never
    /// rendered. Subscribers register in `subscribeToEvents()` and deregister
    /// via the stream's `onTermination`; the registry is lock-boxed so the
    /// `nonisolated` subscribe call stays synchronous.
    private let eventFanOut: BoundedFanOut<GatewayEvent>
    private let gapBroadcaster: GapBroadcaster

    /// P0.1 server→client requests (`approval`, `clarify`, `sudo`, `secret`):
    /// open-request registry + live subscribers. See `ServerRequestBox`.
    private let serverRequests: ServerRequestBox
    private var serverRequestReplies: [String: Task<Void, any Error>] = [:]
    private var nextCapabilitiesID = 0
    private var capabilityRequestID: JSONRPCID?
    private var serverRequestSupportState: ServerRequestSupport = .notAdvertised

    /// H2 Connection health: every lifecycle observation this transport makes
    /// (connect started / connected / disconnected with reason / heartbeat
    /// ping RTT) is yielded here for the FleetCore stats accumulator. The
    /// stream lives for the transport's lifetime and is single-consumer
    /// (the composition root attaches one feed task per gateway connection).
    private let healthStream: AsyncStream<ConnectionHealthEvent>
    private let healthContinuation: AsyncStream<ConnectionHealthEvent>.Continuation

    /// In-flight heartbeat pings keyed by id → send instant, for RTT
    /// measurement. Removed on the correlated pong or the timeout cleanup.
    private var pingStarts: [JSONRPCID: ContinuousClock.Instant] = [:]

    private let clock = ContinuousClock()

    public init(
        baseURL: URL,
        authentication: any AuthenticationProviding,
        sessionFactory: any WebSocketSessionFactory = URLSessionWebSocketSessionFactory(),
        configuration: TransportConfiguration = .standard,
        initialState: TransportState = .disconnected
    ) {
        self.baseURL = baseURL
        self.authentication = authentication
        self.sessionFactory = sessionFactory
        self.config = configuration
        self.stateBox = TransportStateBox(initialState)
        self.lastInbound = .now
        self.lastFrameBox = TransportLastFrameBox()
        let (stream, continuation) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.readyEvents = stream
        self.readyContinuation = continuation
        let (healthStream, healthContinuation) = AsyncStream<ConnectionHealthEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(GatewayEventBudget.maxHealthBacklog))
        self.healthStream = healthStream
        self.healthContinuation = healthContinuation
        let broadcaster = GapBroadcaster()
        self.gapBroadcaster = broadcaster
        self.eventFanOut = BoundedFanOut<GatewayEvent>(
            maxAggregateBytes: GatewayEventBudget.maxAggregateBufferedBytes,
            onGap: { broadcaster.publish($0) })
        self.serverRequests = ServerRequestBox(onGap: { broadcaster.publish($0) })
    }

    /// M1-compatible init: a plain `WSTicketMinting` is adapted to the
    /// `AuthenticationProviding` seam (ticket-only auth).
    public init(
        baseURL: URL,
        ticketMinter: any WSTicketMinting,
        sessionFactory: any WebSocketSessionFactory = URLSessionWebSocketSessionFactory(),
        configuration: TransportConfiguration = .standard,
        initialState: TransportState = .disconnected
    ) {
        self.baseURL = baseURL
        self.authentication = TicketOnlyAuthenticator(ticketMinter: ticketMinter)
        self.sessionFactory = sessionFactory
        self.config = configuration
        self.stateBox = TransportStateBox(initialState)
        self.lastInbound = .now
        self.lastFrameBox = TransportLastFrameBox()
        let (stream, continuation) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.readyEvents = stream
        self.readyContinuation = continuation
        let (healthStream, healthContinuation) = AsyncStream<ConnectionHealthEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(GatewayEventBudget.maxHealthBacklog))
        self.healthStream = healthStream
        self.healthContinuation = healthContinuation
        let broadcaster = GapBroadcaster()
        self.gapBroadcaster = broadcaster
        self.eventFanOut = BoundedFanOut<GatewayEvent>(
            maxAggregateBytes: GatewayEventBudget.maxAggregateBufferedBytes,
            onGap: { broadcaster.publish($0) })
        self.serverRequests = ServerRequestBox(onGap: { broadcaster.publish($0) })
    }

    // MARK: HermesTransport

    /// Establish (or re-establish) the connection.
    ///
    /// P4 (M6): allowed from `.idle`, `.closed` (clean disconnect) and
    /// `.error` (abnormal close) — the reconnect path. The ready-handshake
    /// channel is recreated here so `waitForReady()` always waits on a fresh
    /// stream (the M1 P4 fix). Watermarks are intentionally NOT cleared: they
    /// survive reconnects so replay knows where to resume.
    ///
    /// P0-7: connect() is IDEMPOTENT from `.open` — it returns as a no-op
    /// instead of throwing `invalidState`. The conversation screen is
    /// push/popped while its per-gateway transport stays cached and open
    /// (AppEnvironment keeps one conversation session per gateway), so a
    /// re-entered conversation re-runs its connect flow against an
    /// ALREADY-OPEN shared transport. That must be "already connected", never
    /// an error (dogfood defect: "invalid gateway connection state: connect()
    /// from open" rendered in-conversation on every send after re-entry).
    /// Concurrent callers share the same handshake. Live Ops polling and
    /// approval controls can be the first users of one shared transport.
    public func connect() async throws {
        switch connectionState {
        case .open:
            // P0-7: already connected — idempotent no-op success.
            return
        case .idle, .closed, .error:
            break
        case .connecting:
            return try await withCheckedThrowingContinuation { continuation in
                connectWaiters[connectAttemptID, default: []].append(continuation)
            }
        }
        connectAttemptID += 1
        let attemptID = connectAttemptID
        do {
            try await performConnect()
            let waiters = connectWaiters.removeValue(forKey: attemptID) ?? []
            for waiter in waiters { waiter.resume() }
        } catch {
            let waiters = connectWaiters.removeValue(forKey: attemptID) ?? []
            for waiter in waiters { waiter.resume(throwing: error) }
            throw error
        }
    }

    private func performConnect() async throws {
        connectionState = .connecting
        stateBox.set(.connecting)
        healthContinuation.yield(.connectStarted)

        // Recreate the ready-handshake channel for this connection (M1 P4
        // residual fix): a prior teardown finished the previous channel.
        let (readyStream, readyCont) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream(bufferingPolicy: .bufferingNewest(8))
        readyEvents = readyStream
        readyContinuation = readyCont

        do {
            let authentication = try await self.authentication.authenticate()
            guard let url = Self.buildWebSocketURL(
                base: baseURL, path: "/api/ws", authentication: authentication
            ) else {
                throw TransportError.unableToBuildURL
            }
            let session = sessionFactory.makeSession(url: url)
            self.session = session

            lastInbound = clock.now
            lastFrameBox.setLastFrame(clock.now)
            malformedFrameCount = 0 // P1-4: fresh connection → fresh junk budget
            inFlightToolCalls = 0 // t_a07ca37e: fresh connection → no tools in flight
            lastPingAt = nil // fresh connection → first ping due after one interval
            // Receive-loop FIRST (matching M5): the loop's `receive()` blocks
            // until the socket delivers; opening then guarantees frames are
            // read once they arrive. A stale failure from a PREVIOUS loop is
            // ignored via the session-scoped `handleReceiveFailure` guard.
            startReceiveLoop(session)
            try await session.open()

            let ready = try await waitForReady()
            readyPayload = ready
            connectionState = .open
            stateBox.set(.connected)
            healthContinuation.yield(.connected)

            // Heartbeat is gated on the ready payload — mirror the reference
            // client instead of assuming.
            if ready.heartbeat {
                startHeartbeat(session)
            }
        } catch let error as TransportError {
            await teardown(connectionState == .open ? .normalClosure : .abnormalClosure, error: error)
            throw error
        } catch let error as AuthenticationError {
            // Auth material could not be produced. Classify explicitly; never
            // echo the raw credential (spec §29).
            // P0-9: a rejection the server EXPLAINED is its own class — the
            // tunnel's 401 "no_cookie" means the stored strategy is wrong for
            // this gateway (cookie-only), NOT a bad credential; the UI must
            // say "use username & password sign-in", not "re-authenticate".
            if case .rejected(let reason) = error {
                let wrapped = TransportError.authStrategyRejected(reason)
                await teardown(.reauthenticationRequired, error: wrapped)
                throw wrapped
            }
            // F1: an HTTP status from the auth REST surface is its own class —
            // 401/403 means "credential rejected" (re-auth), anything else
            // means "the endpoint answered but is not the gateway API"
            // (wrong port — do NOT misreport that as an auth problem).
            if case .httpStatus(let code) = error {
                let wrapped = TransportError.authSurfaceStatus(code)
                await teardown(code == 401 || code == 403
                    ? .reauthenticationRequired : .abnormalClosure, error: wrapped)
                throw wrapped
            }
            let wrapped = TransportError.authenticationFailed(Redaction.safeErrorDescription(error))
            await teardown(.reauthenticationRequired, error: wrapped)
            throw wrapped
        } catch {
            let mapped = CloseCodeMapping.reason(for: error)
            await teardown(mapped, error: TransportError.connectionClosed(mapped))
            throw TransportError.connectionClosed(mapped)
        }
    }

    public func disconnect() async {
        await teardown(.normalClosure, error: nil)
    }

    /// The `gateway.ready` payload adopted on the last successful connect
    /// (nil until the handshake completes). Surfaces the M3 adoption seam:
    /// the connectivity layer maps this onto the FleetCore `GatewayReadyAdoption`.
    public func adoptedReady() -> GatewayEvent.ReadyPayload? {
        readyPayload
    }

    // MARK: P4 — watermark tracking (the transport sees every event)

    /// The highest observed `seq` for a session (0 when never observed).
    /// Persists across disconnect so a reconnecting client can resume replay
    /// from exactly where it stopped.
    public func watermark(for sessionID: String) -> Int {
        sessionWatermarks[sessionID] ?? 0
    }

    /// All tracked per-session watermarks (sessionID → highest observed seq).
    public func allWatermarks() -> [String: Int] {
        sessionWatermarks
    }

    /// Drop all watermarks — call on replay-epoch change (gateway restart);
    /// stale seq assumptions must be discarded and the client rehydrates from
    /// server state (spec §9.6).
    public func clearWatermarks() {
        sessionWatermarks.removeAll()
        watermarkTouch.removeAll()
    }

    /// Sessions whose parked live frames were dropped by the hold cap during
    /// the last replay pass (cleared on read).
    public func takeReplayHoldOverflowSessions() -> Set<String> {
        defer { replayHoldOverflowSessions.removeAll() }
        return replayHoldOverflowSessions
    }

    /// Sessions (and whether ALL sessions) that may be incomplete because a
    /// bound forced the transport to lose track; cleared on read. The replay
    /// engine turns these into `.truncated` / `.historyIncomplete` outcomes so
    /// the UI refetches authoritative history.
    public func takeIncompleteSessions() -> (sessions: Set<String>, all: Bool) {
        defer { incompleteSessions.removeAll(); incompleteAll = false }
        return (incompleteSessions, incompleteAll)
    }

    private func markIncomplete(_ sessionID: String?, reason: EventGap.Reason) {
        if let sessionID {
            if incompleteSessions.count < Self.maxTrackedSessions || incompleteSessions.contains(sessionID) {
                incompleteSessions.insert(sessionID)
            } else {
                incompleteAll = true
            }
        } else {
            incompleteAll = true
        }
        gapBroadcaster.publish(EventGap(sessionID: sessionID, reason: reason))
    }

    /// Introspection for budget tests: bytes/subscribers currently buffered.
    nonisolated var subscriberBufferedBytes: Int { eventFanOut.totalBytes }
    nonisolated var eventSubscriberCount: Int { eventFanOut.subscriberCount }
    var replayHoldBufferedBytes: Int { replayHoldBytes }
    func takeReplayHoldOverflowSessionsPeek() -> Bool { replayHoldOverflowSessions.isEmpty }

    /// Live gaps (see `EventGap`). Each call returns a fresh bounded stream.
    public nonisolated func subscribeToGaps() -> AsyncStream<EventGap> {
        gapBroadcaster.subscribe()
    }

    // MARK: P4 — replay hold

    /// Park inbound event frames for watermarked sessions until
    /// `endReplayHold()` is called. Used by the replay engine so a replayed
    /// `session.events.since` batch can be injected in order before live
    /// frames resume (spec §10 "park live frames during replay").
    public func beginReplayHold() {
        replayHoldActive = true
        replayHoldBuffer.removeAll()
        replayHoldOverflowSessions.removeAll()
        replayHoldBytes = 0
    }

    /// Resume forwarding, flushing parked frames seq-gated: frames with
    /// seq ≤ the current watermark are dropped (dedupe against what replay
    /// already injected); the rest are forwarded in arrival order.
    public func endReplayHold() {
        replayHoldActive = false
        let held = replayHoldBuffer
        replayHoldBuffer.removeAll()
        replayHoldBytes = 0
        for event in held {
            // Replay-hold dedupe (spec §10): drop seq ≤ watermark — those
            // frames were already applied (replayed) or are stale; only
            // strictly-newer live frames resume.
            if let sessionID = event.sessionID, let seq = event.seq {
                if seq <= (sessionWatermarks[sessionID] ?? 0) {
                    continue
                }
            }
            forward(event, advanceWatermark: true)
        }
    }

    /// Inject a replayed event (from `session.events.since`) into the live
    /// event channel, advancing the session watermark so dedupe knows it was
    /// applied. Used by the replay engine during `beginReplayHold()`.
    public func injectReplayedEvents(_ events: [GatewayEvent]) {
        for event in events {
            forward(event, advanceWatermark: true)
        }
    }

    /// Advance a session's watermark to a specific seq (typically
    /// `latest_seq` from a replay response that carried no newer event frames,
    /// or after a truncated batch) so the next replay resumes from there.
    /// Watermarks are monotonic: this never lowers one.
    public func advanceWatermark(to seq: Int, for sessionID: String) {
        recordWatermark(seq, for: sessionID)
    }

    /// Monotonic watermark update. A session beyond `maxTrackedSessions` is not
    /// tracked (its events still flow live); the table cannot grow without bound.
    private func recordWatermark(_ seq: Int, for sessionID: String) {
        touchClock &+= 1
        if let current = sessionWatermarks[sessionID] {
            sessionWatermarks[sessionID] = max(current, seq)
        } else {
            if sessionWatermarks.count >= Self.maxTrackedSessions,
               let coldest = watermarkTouch.min(by: { $0.value < $1.value })?.key {
                // Evict the least recently active session, never the one
                // being updated: an active conversation keeps its watermark.
                // The evicted session can no longer be replayed exactly, so it
                // is marked incomplete rather than silently forgotten.
                sessionWatermarks.removeValue(forKey: coldest)
                watermarkTouch.removeValue(forKey: coldest)
                markIncomplete(coldest, reason: .watermarkEvicted)
            }
            sessionWatermarks[sessionID] = seq
        }
        watermarkTouch[sessionID] = touchClock
    }

    // MARK: RPC request/response (M2 — roster RPCs)

    /// Send a JSON-RPC request and await the correlated response/error.
    ///
    /// M2 uses this for `profiles.list` / `session.list` (roster RPCs); M4/M5
    /// reuse it for the read + conversation paths; P4 uses it for
    /// `session.events.since`.
    ///
    /// Implementation (ADR-style): the continuation is registered synchronously
    /// on the actor, then a timeout task races it. The timeout task and the
    /// send task BOTH route through `failPending`, which removes-and-resumes
    /// the continuation exactly once — so a silent gateway or a dropped socket
    /// yields a classification (`requestTimeout` / `connectionClosed`) instead
    /// of a hung caller, and a late response to a timed-out request is a no-op.
    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard connectionState == .open else {
            throw TransportError.invalidState("request from \(connectionState)")
        }
        guard let session else {
            throw TransportError.invalidState("request with no session")
        }
        nextRequestID += 1
        // String request ids (rpc-N), mirroring the heartbeat's heartbeat-N:
        // the fixture server and correlation map both key on the string form.
        let id = JSONRPCID.string("rpc-\(nextRequestID)")
        let frame = JSONRPCRequest(id: id, method: method, params: params)
        let line = try JSONRPCCodec.encode(.request(frame))

        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, any Error>) in
            pendingRequests[id] = cont
            // Send on a detached task so a send failure can fail the pending
            // continuation rather than leaving it dangling.
            Task { [weak self] in
                guard let self else {
                    cont.resume(throwing: TransportError.transportFailure("transport deallocated"))
                    return
                }
                do {
                    try await session.send(.text(line))
                } catch {
                    await self.failPending(id: id, error: TransportError.transportFailure("send failed: \(Redaction.safeErrorDescription(error))"))
                }
            }
            // Timeout race: fail the pending continuation if no response
            // arrived within requestTimeout.
            Task { [weak self, config] in
                try? await Task.sleep(for: config.requestTimeout)
                await self?.failPending(id: id, error: TransportError.requestTimeout)
            }
        }
        // P0.1 reconnect contract: `session.resume` / `session.activate` /
        // `session.events.since` answer with `open_requests` — the server→
        // client requests still waiting on the session. They are not events
        // (the replay ring cannot carry "a question still waiting"), so they
        // are re-delivered here, before the caller sees the result.
        if Self.openRequestMethods.contains(method) {
            await ingestOpenRequests(from: result)
        }
        return result
    }

    /// Methods whose result carries `open_requests`.
    private static let openRequestMethods: Set<String> = [
        "session.resume", "session.activate", "session.events.since",
    ]

    /// Remove-and-resume a pending continuation exactly once.
    ///
    /// Safe under racing: only the first caller finds the id still registered;
    /// a response arriving after a timeout (or a duplicate timeout) is a no-op.
    private func failPending(id: JSONRPCID, error: any Error) async {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    // MARK: handshake

    private func waitForReady() async throws -> GatewayEvent.ReadyPayload {
        do {
            return try await withThrowingTaskGroup(of: GatewayEvent.ReadyPayload.self) { group in
                group.addTask { [readyEvents] in
                    for await payload in readyEvents {
                        return payload
                    }
                    throw TransportError.readyTimeout
                }
                group.addTask { [config] in
                    try await Task.sleep(for: config.connectTimeout)
                    throw TransportError.readyTimeout
                }
                guard let result = try await group.next() else {
                    throw TransportError.readyTimeout
                }
                group.cancelAll()
                return result
            }
        } catch TransportError.readyTimeout {
            // The handshake stream ended without a payload. If the socket
            // actually died during the handshake (unreachable host, closed
            // socket), surface the classified reason instead of a bare
            // timeout — that is the M3 reachable/unreachable distinction.
            // A still-open silent server leaves `connectionState == .connecting`
            // here, so it correctly remains `.readyTimeout`.
            if case .error(let reason) = connectionState {
                throw TransportError.connectionClosed(reason)
            }
            throw TransportError.readyTimeout
        }
    }

    // MARK: receive loop

    private func startReceiveLoop(_ session: any WebSocketSession) {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await session.receive()
                    await self.handleInbound(message)
                }
            } catch {
                // Only tear down if this loop still owns the current session:
                // a stale failure from a PREVIOUS connection's loop must not
                // clobber a freshly-opened reconnect (P4).
                await self.handleReceiveFailure(error, for: session)
            }
        }
    }

    private func handleInbound(_ message: WebSocketMessage) async {
        switch message {
        case .text(let line):
            // Refuse an oversized frame BEFORE decoding it (no parse, no
            // retained structure). Its session is unknown, so every session is
            // marked possibly incomplete and a gap is published.
            if line.utf8.count > GatewayEventBudget.maxFrameBytes {
                markIncomplete(nil, reason: .oversizedFrame)
                await recordMalformedFrame()
                return
            }
            // Decode BEFORE touching liveness (P1-4): a malformed text frame
            // is junk, not liveness — it must not keep a bad peer alive.
            guard let decoded = try? JSONRPCCodec.decode(line) else {
                await recordMalformedFrame()
                return
            }
            // Valid protocol frame (event / response / error / request) — the
            // only inbound traffic that counts as liveness. Heartbeat pongs
            // arrive as correlated `.response`s and refresh here too.
            await setLastInbound()
            malformedFrameCount = 0
            await handleDecoded(decoded)
        case .data(let data):
            // /api/ws is text-only; binary frames are junk (P1-4). They must
            // neither refresh liveness nor be silently tolerated forever.
            if data.count > GatewayEventBudget.maxFrameBytes {
                markIncomplete(nil, reason: .oversizedFrame)
            }
            await recordMalformedFrame()
        }
    }

    private func setLastInbound() {
        lastInbound = clock.now
        lastFrameBox.setLastFrame(lastInbound)
    }

    /// P1-4: count a junk frame (binary data or text failing JSON-RPC decode).
    /// Consecutive junk past the bounded limit closes + classifies the
    /// connection as abnormal — a bad/malformed peer can no longer masquerade
    /// as "connected" forever by spamming junk that (pre-fix) refreshed
    /// liveness.
    private func recordMalformedFrame() async {
        malformedFrameCount += 1
        if malformedFrameCount >= config.malformedFrameLimit {
            await teardown(.abnormalClosure, error: TransportError.connectionClosed(.abnormalClosure))
        }
    }

    private func handleDecoded(_ decoded: JSONRPCMessage) async {
        switch decoded {
        case .event(let event):
            guard let gatewayEvent = GatewayEvent(event: event) else { return }
            await handleEvent(gatewayEvent)
        case .response(let response):
            if response.id == capabilityRequestID {
                // P0.1: the gateway's `client.capabilities` answer — the
                // request methods it may send.
                capabilityRequestID = nil
                let methods = response.result?["server_requests"]?.arrayValue?.compactMap(\.stringValue) ?? []
                serverRequestSupportState = .acknowledged(methods: methods)
                return
            }
            // H2: a correlated heartbeat pong measures ping RTT (the ping's
            // send instant was recorded in `sendPing`). Heartbeat ids are
            // never in `pendingRequests`, so this lookup is unambiguous.
            if let start = pingStarts.removeValue(forKey: response.id) {
                healthContinuation.yield(.pingRTT(
                    milliseconds: Self.elapsedMilliseconds(from: start, to: clock.now)))
            } else if let continuation = pendingRequests.removeValue(forKey: response.id) {
                // Correlate with a pending RPC request (M2: profiles.list /
                // session.list) by exact id. Unknown/duplicate ids are
                // ignored — a late response to a timed-out request must not
                // crash.
                continuation.resume(returning: response.result ?? .null)
            }
        case .error(let error):
            if error.id == capabilityRequestID {
                // An older gateway (no `client.capabilities`, or no server
                // requests): nothing is promised; the legacy event path serves.
                capabilityRequestID = nil
                serverRequestSupportState = .refused
                return
            }
            if let continuation = pendingRequests.removeValue(forKey: error.id) {
                continuation.resume(throwing: error.error)
            }
        case .request(let request):
            // P0.1: a server→client request (the gateway asks; the user
            // answers). Only clients that advertised `server_requests` get
            // these, and the advertisement is sent on every `gateway.ready`.
            await handleServerRequest(
                id: request.id, method: request.method, params: request.params, replayed: false)
        }
    }

    private func handleEvent(_ event: GatewayEvent) async {
        // P4 (M6): during a replay pass, park inbound event frames for
        // sessions instead of forwarding, so replayed events inject first.
        // `gateway.ready` has no session_id and always forwards (it is also
        // the only event routed to the ready channel).
        if replayHoldActive, let sessionID = event.sessionID, event.seq != nil {
            let bytes = GatewayEventBudget.estimatedBytes(of: event)
            if replayHoldBuffer.count < Self.maxReplayHoldEvents,
               replayHoldBytes + bytes <= Self.maxReplayHoldBytes {
                replayHoldBuffer.append(event)
                replayHoldBytes += bytes
            } else if replayHoldOverflowSessions.count < Self.maxTrackedSessions
                        || replayHoldOverflowSessions.contains(sessionID) {
                // Over the count or byte budget: drop the frame but remember
                // the session so the caller rehydrates it instead of trusting
                // a silent gap.
                replayHoldOverflowSessions.insert(sessionID)
            } else {
                incompleteAll = true
            }
            return
        }
        forward(event, advanceWatermark: true)
        // t_a07ca37e: tool-in-flight accounting for the extended reconnect
        // window (18s → 25s). Only STARTED-vs-COMPLETED pairing on this
        // transport is tracked; a turn terminal frame is the backstop that
        // drains any unpaired starts (a gateway that emits tool.complete
        // for every tool.start makes the counter settle at 0 naturally).
        switch event.type {
        case .toolStart:
            inFlightToolCalls += 1
        case .toolComplete, .backgroundComplete:
            inFlightToolCalls = max(0, inFlightToolCalls - 1)
        case .messageComplete:
            if inFlightToolCalls > 0 { inFlightToolCalls = 0 }
        default:
            break
        }
        switch event.type {
        case .gatewayReady:
            let payload = event.ready ?? GatewayEvent.ReadyPayload(
                skin: nil, changeEvents: false, heartbeat: false, replayEpoch: nil)
            readyContinuation.yield(payload)
            // P0.1: tell the gateway, once per connection and only after
            // `gateway.ready`, that this client answers server→client
            // requests. A WebSocket client that never says so is treated as a
            // build that predates them and every approval is withdrawn.
            if config.advertisesServerRequests {
                await advertiseServerRequestCapability()
            }
        case .error:
            // Surface transport-level error events; P1 just records them.
            break
        case .sessionInfo, .messageStart, .messageDelta, .messageInterim,
             .messageComplete, .thinkingDelta, .reasoningDelta,
             .reasoningAvailable, .statusUpdate, .toolStart, .toolGenerating,
             .toolProgress, .toolComplete, .backgroundComplete,
             .approvalRequest, .usageUpdate, .sessionTitle, .requestCancel, .unknown:
            // Conversation/streaming events are forwarded via the event
            // channel above; the transport itself does not interpret them.
            break
        }
    }

    /// Deliver one event to every live subscriber and advance the session
    /// watermark (when `advanceWatermark` is true). Replayed events and live
    /// frames both pass through here so watermarks stay monotonic.
    private func forward(_ event: GatewayEvent, advanceWatermark: Bool) {
        // P0.1: `request.cancel {id, ...}` withdraws an open server request.
        // Settle it here so live frames and replayed events behave the same;
        // the event itself still reaches subscribers so the UI dismisses the
        // matching prompt (never as a denial).
        if event.type == .requestCancel, let id = event.payload?["id"]?.stringValue {
            serverRequests.settle(id)
        }
        let bytes = GatewayEventBudget.estimatedBytes(of: event)
        eventFanOut.yield(event, bytes: bytes, sessionID: event.sessionID,
                          pinned: event.type == .requestCancel || event.type == .approvalRequest)
        serverRequests.forwardConversation(event, bytes: bytes)
        if advanceWatermark, let sessionID = event.sessionID, let seq = event.seq {
            recordWatermark(seq, for: sessionID)
        }
    }

    /// Subscribe to the gateway's inbound event stream (M5 conversation
    /// streaming). Each call returns a FRESH stream yielding every decoded
    /// `GatewayEvent` in arrival order; the subscription lives until the
    /// consumer's iteration ends (view model deallocation cancels it), at
    /// which point it is deregistered. P0-7: previously this handed out ONE
    /// single-consumer channel, so a re-entered conversation (new view model
    /// after pop) iterated a dead stream and never rendered replies — the
    /// fan-out here is what makes conversation re-entry work.
    public nonisolated func subscribeToEvents() -> AsyncStream<GatewayEvent> {
        // Bounded by count AND bytes; an overflow publishes a gap (never a
        // silent drop). A stream that is created but never iterated stays
        // registered (bounded) until the transport is released.
        eventFanOut.makeStream(maxCount: Self.maxSubscriberBacklog,
                               maxBytes: GatewayEventBudget.maxSubscriberBacklogBytes)
    }

    // MARK: P0.1 — server→client requests

    /// Subscribe to server→client requests (`approval`, `clarify`, `sudo`,
    /// `secret`). The stream first yields every request that is open right
    /// now (marked `replayed`), then live ones, so a screen that subscribes
    /// after a request arrived — or after a reconnect re-delivered it through
    /// `open_requests` — still sees it. Each call returns a fresh stream.
    public nonisolated func subscribeToServerRequests() -> AsyncStream<ServerRequest> {
        let (stream, continuation) = AsyncStream<ServerRequest>.makeStream()
        let token = serverRequests.subscribe(continuation)
        continuation.onTermination = { [serverRequests] _ in
            serverRequests.unsubscribe(token)
        }
        return stream
    }

    /// Conversation events, requests and withdrawals in transport order.
    public nonisolated func subscribeToConversationEvents() -> AsyncStream<ConversationEvent> {
        let (token, queue) = serverRequests.subscribeConversation(
            maxCount: Self.maxSubscriberBacklog, maxBytes: GatewayEventBudget.maxSubscriberBacklogBytes)
        // Lease-owned deregistration (see `BoundedFanOut.makeStream`): a stream
        // that is dropped without being iterated still releases its queue.
        let lease = Lease { [serverRequests] in serverRequests.unsubscribeConversation(token) }
        return AsyncStream<ConversationEvent>(unfolding: {
            _ = lease
            return await queue.next()
        }, onCancel: { [serverRequests] in
            serverRequests.unsubscribeConversation(token)
        })
    }

    /// Number of server requests currently open on this transport.
    public nonisolated var openServerRequestCount: Int { serverRequests.openCount }

    /// Answer an open server→client request with a JSON-RPC RESPONSE carrying
    /// its id. Idempotent per id: an id already answered or withdrawn is not
    /// sent again (a stale card answering twice is a no-op on the wire).
    /// Throws when the connection is down, leaving the request open so the
    /// user can retry — a failed answer must never look like success.
    public func respondToServerRequest(id: String, result: JSONValue) async throws {
        guard !serverRequests.isSettled(id) else { return }
        // Actor methods are reentrant during socket send. Concurrent taps
        // share the same send and its failure rather than sending twice or
        // reporting success while the first answer can still fail.
        if let reply = serverRequestReplies[id] {
            try await reply.value
            return
        }
        let reply = Task {
            try await self.sendServerRequestReply(id: id) { wireID in
                .response(JSONRPCResponse(id: wireID, result: result))
            }
        }
        serverRequestReplies[id] = reply
        defer { serverRequestReplies[id] = nil }
        try await reply.value
        serverRequests.settle(id)
    }

    /// Mark a request settled without sending a response (the last
    /// `clarify.lock` resolved it server-side, or the gateway said it expired).
    public func settleServerRequest(id: String) {
        serverRequests.settle(id)
    }

    private func sendServerRequestReply(
        id: String, message: (JSONRPCID) -> JSONRPCMessage
    ) async throws {
        guard connectionState == .open, let session else {
            throw TransportError.invalidState("server request answer from \(connectionState)")
        }
        // Echo the id exactly as it arrived (string or number); after a
        // reconnect the registry is re-filled by `open_requests` with the
        // gateway's own ids, which are strings.
        guard !serverRequests.isSettled(id) else { return }
        guard let wireID = serverRequests.wireID(for: id) else {
            throw TransportError.invalidState("server request is no longer open")
        }
        let line = try JSONRPCCodec.encode(message(wireID))
        do {
            try await session.send(.text(line))
        } catch {
            throw TransportError.transportFailure(
                "server request response could not be sent")
        }
    }

    /// Route one server→client request. Methods Fleet does not implement get
    /// JSON-RPC `-32601`, and a supported method with unusable params gets
    /// `-32602`, so the agent fails fast instead of waiting out its deadline.
    /// A supported request is parked in the registry and delivered to
    /// subscribers; it is answered later by the user (or withdrawn by
    /// `request.cancel`).
    private func handleServerRequest(
        id: JSONRPCID, method: String, params: JSONValue?, replayed: Bool
    ) async {
        switch GatewayServerRequestDecoder.decode(
            id: id, method: method, params: params, replayed: replayed) {
        case .failure(let error):
            await replyWithError(id: id, error: error)
        case .success(let request):
            switch serverRequests.admit(.init(wireID: id, request: request)) {
            case .admitted, .duplicate, .settled:
                break
            case .full:
                await replyWithError(id: id, error: JSONRPCError(
                    code: JSONRPCError.internalError.code,
                    message: "too many open server requests"))
            }
        }
    }

    private func replyWithError(id: JSONRPCID, error: JSONRPCError) async {
        guard let session,
              let line = try? JSONRPCCodec.encode(
                .error(JSONRPCErrorResponse(id: id, error: error))) else { return }
        try? await session.send(.text(line))
        serverRequests.settle(id.wireValue)
    }

    /// Re-deliver the `open_requests` of a resume / activate / events.since
    /// result as if they had just arrived (ids are preserved, so a card that
    /// survived the reconnect keeps its identity and answers the same request).
    private func ingestOpenRequests(from result: JSONValue) async {
        for entry in GatewayServerRequestDecoder.openRequestEntries(in: result) {
            await handleServerRequest(
                id: entry.id, method: entry.method, params: entry.params, replayed: true)
        }
    }

    /// `client.capabilities {server_requests: true}` — sent once per connection
    /// after `gateway.ready`, only when the configuration opts in. The reply
    /// is correlated by its own id (never in `pendingRequests`) and recorded
    /// as `serverRequestSupport()`; a `-32601` from an older gateway is not a
    /// failure of the connection.
    private func advertiseServerRequestCapability() async {
        guard let session else { return }
        nextCapabilitiesID += 1
        let id = JSONRPCID.string("caps-\(nextCapabilitiesID)")
        let frame = JSONRPCRequest(
            id: id,
            method: "client.capabilities",
            params: .object(["server_requests": .bool(true)]))
        guard let line = try? JSONRPCCodec.encode(.request(frame)) else { return }
        capabilityRequestID = id
        serverRequestSupportState = .pending
        try? await session.send(.text(line))
    }

    /// What the gateway said about server→client requests on the current
    /// connection. UI must not promise prompt kinds beyond an
    /// `.acknowledged` list; `.refused` means an older gateway (the legacy
    /// `approval.request` event path applies).
    public func serverRequestSupport() -> ServerRequestSupport {
        serverRequestSupportState
    }

    /// H2 Connection health: subscribe to the transport's lifecycle
    /// observations (`.connectStarted` / `.connected` / `.disconnected(reason)`
    /// / `.pingRTT(ms)`). Lives for the transport's lifetime; the composition
    /// root attaches one consumer task that feeds the FleetCore accumulator.
    public nonisolated func subscribeToHealthEvents() -> AsyncStream<ConnectionHealthEvent> {
        healthStream
    }

    // MARK: heartbeat

    private func startHeartbeat(_ session: any WebSocketSession) {
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            let pingInterval = self.config.pingInterval
            let checkingInterval = self.config.livenessTiming.checkingInterval
            while !Task.isCancelled {
                // t_a07ca37e: the liveness check runs at `checkingInterval`
                // (5s) cadence; pings still go out every `pingInterval`. With
                // the default 15s ping this evaluates three times per ping
                // cycle, so the tiered reconnect windows are honored at 5s
                // granularity. A pingInterval SHORTER than the checking
                // interval (tests) collapses to the ping cadence.
                let tick = min(pingInterval, Duration.seconds(checkingInterval))
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    break
                }
                if Task.isCancelled { break }
                let dueForPing = await self.isPingDue(pingInterval: pingInterval)
                if dueForPing {
                    await self.sendPing(session)
                }
                await self.evaluateLiveness()
            }
        }
    }

    /// Whether a ping is due on this tick (the loop may run faster than the
    /// ping cadence now that liveness checks and pings are decoupled).
    private var lastPingAt: ContinuousClock.Instant?

    private func isPingDue(pingInterval: Duration) -> Bool {
        let now = clock.now
        if let lastPingAt {
            return now - lastPingAt >= pingInterval
        }
        return true
    }

    private func evaluateLiveness() async {
        // t_a07ca37e: ONE tiered liveness verdict folding heartbeat freshness
        // into the same evaluation the malformed-frame counter feeds (P1-4:
        // junk never refreshes `lastInbound`, so a junk-spamming peer goes
        // stale exactly as before — unchanged semantics).
        let snapshot = ConnectionLivenessSnapshot(lastFrameReceivedAt: lastInbound)
        let tier = snapshot.tier(
            now: clock.now,
            toolInFlight: inFlightToolCalls > 0,
            timing: config.livenessTiming
        )
        switch tier {
        case .fresh, .checkDue:
            // fresh (<12s): provably alive — nothing to do. checkDue
            // (>12s, < reconnect window): escalation is the ACTIVE liveness
            // probe itself — the ping sent on this same tick. No teardown.
            break
        case .stale:
            await teardown(.abnormalClosure, error: TransportError.connectionClosed(.abnormalClosure))
        }
    }

    private func sendPing(_ session: any WebSocketSession) async {
        nextHeartbeatID += 1
        lastPingAt = clock.now // t_a07ca37e: ping cadence tracking (decoupled from liveness checks)
        let id = JSONRPCID.string("heartbeat-\(nextHeartbeatID)")
        let frame = JSONRPCRequest(id: id, method: "gateway.ping", params: .object([:]))
        do {
            let line = try JSONRPCCodec.encode(.request(frame))
            // Record the send instant BEFORE sending; the correlated pong in
            // the receive loop yields a `.pingRTT` health event (H2).
            pingStarts[id] = clock.now
            try await session.send(.text(line))
            // Timeout hygiene: drop the sample if no pong arrives so the
            // dictionary never grows unbounded. The heartbeat loop itself
            // never blocks on the pong (inbound-deadline detection stays live).
            let deadline = config.requestTimeout
            Task { [weak self, id] in
                try? await Task.sleep(for: deadline)
                await self?.dropPingIfUnanswered(id: id)
            }
        } catch {
            // Send failure will surface via the receive loop / close path.
        }
    }

    /// Remove an unanswered heartbeat ping (a late pong is a no-op — the
    /// sample was already dropped).
    private func dropPingIfUnanswered(id: JSONRPCID) {
        pingStarts[id] = nil
    }

    // MARK: teardown

    private func handleReceiveFailure(_ error: any Error, for failedSession: any WebSocketSession) async {
        // Ignore a failure from a session that is no longer current — the
        // reconnect already replaced it and its own loop owns teardown (P4).
        guard let current = session, isSame(current, failedSession) else { return }
        // Prefer the close code captured by the delegate; fall back to error
        // mapping. RACE GUARD: URLSession can surface the receive error
        // BEFORE the delegate's didCloseWith records the code — the two
        // notifications arrive on independent queues with no ordering
        // guarantee. The classification is terminal (teardown state is
        // never revisited), so mis-ordering would permanently misclassify
        // an application close (e.g. 4401 → auth-required) as an abnormal
        // offline. Briefly yield for the delegate notification (bounded:
        // a socket-death close NEVER delivers a code — the maximum wait is
        // wasted latency, and only on an already-failed connection).
        var code = failedSession.lastCloseCode
        if code == nil {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms x 10 = 200ms ceiling
                code = failedSession.lastCloseCode
                if code != nil { break }
            }
        }
        // A message above `maximumMessageSize` surfaces as POSIX EMSGSIZE (40,
        // observed) or close code 1009. The refused message's session is
        // unknown, and a session with no watermark yet is not covered by
        // `events.since`, so mark every session possibly incomplete.
        let nsError = error as NSError
        if code == 40 || code == 1009 || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 40) {
            markIncomplete(nil, reason: .oversizedFrame)
        }
        if let code {
            let reason = CloseCodeMapping.reason(forRawCode: code)
            await teardown(reason, error: TransportError.connectionClosed(reason))
        } else {
            let reason = CloseCodeMapping.reason(for: error)
            await teardown(reason, error: TransportError.connectionClosed(reason))
        }
    }

    /// Identity comparison for `any WebSocketSession` (class-based fakes and
    /// the URLSession implementation are reference types).
    private func isSame(_ a: any WebSocketSession, _ b: any WebSocketSession) -> Bool {
        a as AnyObject === b as AnyObject
    }

    private func teardown(_ reason: DisconnectReason, error: (any Error)?) async {
        // D1 (M13 HOLD): record the terminal connection state BEFORE finishing
        // the per-connection ready channel. waitForReady() classifies a failed
        // handshake by sampling connectionState at the instant the ready stream
        // ends — if the socket died during the handshake, that sample must see
        // `.error(reason)` (→ `.unreachable`), never the still-`.connecting`
        // state that previously existed while teardown was suspended at the
        // session close await (→ `.timeout`). A still-open silent server never
        // reaches teardown, so `.connecting` there still correctly maps to
        // `.readyTimeout` in waitForReady().
        let wasTerminal: Bool
        switch connectionState {
        case .closed, .error: wasTerminal = true
        default: wasTerminal = false
        }
        // t_a07ca37e: freshness is only proof of liveness for an OPEN
        // transport — drop the snapshot on teardown so the status watcher's
        // poll gate resumes immediately after a disconnect instead of
        // trusting a last-frame timestamp from a dead connection.
        lastFrameBox.clear()
        // P0.1: the gateway keeps its open server requests and re-delivers
        // them through `open_requests` on resume; drop this connection's copy.
        serverRequests.clearOpen()
        capabilityRequestID = nil
        serverRequestSupportState = .notAdvertised
        // Fail every in-flight RPC request so awaiters never hang: a dropped
        // socket is a classification, not an endless await.
        let pending = pendingRequests
        pendingRequests.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: TransportError.connectionClosed(reason))
        }
        receiveLoopTask?.cancel()
        heartbeatTask?.cancel()
        receiveLoopTask = nil
        heartbeatTask = nil
        // Record the terminal state before any suspension / channel finish so
        // waitForReady()'s classification is deterministic (D1).
        guard !wasTerminal else {
            lastDisconnectReason = reason
            readyContinuation.finish()
            await session?.close(code: 1000, reason: nil)
            session = nil
            replayHoldActive = false
            replayHoldBuffer.removeAll()
            replayHoldBytes = 0
            replayHoldOverflowSessions.removeAll()
            _ = error
            return
        }
        switch reason {
        case .normalClosure:
            connectionState = .closed
            stateBox.set(.disconnected)
        default:
            connectionState = .error(reason)
            stateBox.set(.failed(reason.debugDescription))
        }
        lastDisconnectReason = reason
        // H2: emit the disconnect observation exactly once per actual state
        // transition (repeat teardowns are the `wasTerminal` path above and
        // do NOT re-emit). The reason string is `DisconnectReason.debugDescription`
        // — non-secret by construction.
        healthContinuation.yield(.disconnected(reason: reason.debugDescription))
        // P4 (M6): finish the per-connection ready channel (waitForReady on
        // the closing connection must fail fast); the event channel is NOT
        // finished so a reconnecting client keeps its live subscription.
        readyContinuation.finish()
        await session?.close(code: 1000, reason: nil)
        session = nil
        replayHoldActive = false
        replayHoldBuffer.removeAll()
        _ = error // recorded; P1 surfaces via state only
    }

    // MARK: URL building

    /// Build `ws(s)://host:port/api/ws` with the connection's authentication
    /// query (`?ticket=...` for a single-use ticket, `?token=...` for a
    /// loopback token, or no auth query). Matches `buildHermesWebSocketUrl`.
    /// The returned URL contains the secret auth value — never log it directly;
    /// use `Redaction.redactedURL(_:)` (spec §29).
    public static func buildWebSocketURL(
        base: URL,
        path: String,
        authentication: ConnectionAuthentication
    ) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        components.path = GatewayEndpoint.path(joining: path, onto: base)
        var query = components.queryItems ?? []
        switch authentication {
        case .none:
            break
        case .ticket(let token):
            query.append(URLQueryItem(name: "ticket", value: token.rawValue))
        case .loopbackToken(let token):
            query.append(URLQueryItem(name: "token", value: token.rawValue))
        }
        components.queryItems = query
        return components.url
    }

    /// M1-compatible ticket-only URL builder (single-use `?ticket=`).
    public static func buildWebSocketURL(base: URL, path: String, ticket: WSTicket) -> URL? {
        buildWebSocketURL(
            base: base, path: path,
            authentication: .ticket(StoredToken(rawValue: ticket.token)))
    }

    /// Milliseconds between two `ContinuousClock` instants (non-negative).
    /// Used to convert a ping send→pong round-trip into a `Double` ms sample.
    static func elapsedMilliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
        return max(0, Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)
    }
}

/// t_a07ca37e: lock-boxed mirror of the transport's last-valid-frame
/// instant, so the `nonisolated` `liveness` accessor (consumed off-actor by
/// the view model's status watcher) reads freshness without hopping to the
/// transport actor. `OSAllocatedUnfairLock` is async-safe (scoped locking),
/// matching `TransportStateBox`. Nil until the first connection opens.
final class TransportLastFrameBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    func setLastFrame(_ instant: ContinuousClock.Instant) {
        lock.withLock { $0 = instant }
    }

    /// Drop the freshness signal (teardown): a last-frame timestamp only
    /// proves liveness of an OPEN transport — after a disconnect it must
    /// not keep consumers (the status watcher's poll gate) trusting a
    /// dead connection.
    func clear() {
        lock.withLock { $0 = nil }
    }

    func read() -> ConnectionLivenessSnapshot? {
        lock.withLock { instant in
            instant.map(ConnectionLivenessSnapshot.init)
        }
    }
}
