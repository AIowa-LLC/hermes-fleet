import Foundation
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

    // MARK: lifecycle state (actor-isolated)
    private var connectionState: ConnectionState = .idle
    private var session: (any WebSocketSession)?
    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastInbound: ContinuousClock.Instant
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

    /// Inbound event channel (M5): every decoded `GatewayEvent` is yielded
    /// here so the conversation client can subscribe to streamed turn events
    /// (`message.*`, `tool.*`, `status.*`, `thinking/reasoning.*`,
    /// `message.complete`, …). Unbounded buffering means a subscriber attached
    /// after events begin arriving still receives them in order. Single
    /// consumer: one conversation client per gateway subscribes.
    ///
    /// P4 (M6): the channel lives for the transport's lifetime — it is NOT
    /// finished at teardown — so a reconnecting conversation client keeps
    /// receiving replayed + live events on the same stream.
    private let eventStream: AsyncStream<GatewayEvent>
    private let eventContinuation: AsyncStream<GatewayEvent>.Continuation

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
        let (stream, continuation) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream()
        self.readyEvents = stream
        self.readyContinuation = continuation
        let (eventStream, eventContinuation) = AsyncStream<GatewayEvent>.makeStream()
        self.eventStream = eventStream
        self.eventContinuation = eventContinuation
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
        let (stream, continuation) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream()
        self.readyEvents = stream
        self.readyContinuation = continuation
        let (eventStream, eventContinuation) = AsyncStream<GatewayEvent>.makeStream()
        self.eventStream = eventStream
        self.eventContinuation = eventContinuation
    }

    // MARK: HermesTransport

    /// Establish (or re-establish) the connection.
    ///
    /// P4 (M6): allowed from `.idle`, `.closed` (clean disconnect) and
    /// `.error` (abnormal close) — the reconnect path. The ready-handshake
    /// channel is recreated here so `waitForReady()` always waits on a fresh
    /// stream (the M1 P4 fix). Watermarks are intentionally NOT cleared: they
    /// survive reconnects so replay knows where to resume.
    public func connect() async throws {
        switch connectionState {
        case .idle, .closed, .error:
            break
        default:
            throw TransportError.invalidState("connect() from \(connectionState)")
        }
        connectionState = .connecting
        stateBox.set(.connecting)

        // Recreate the ready-handshake channel for this connection (M1 P4
        // residual fix): a prior teardown finished the previous channel.
        let (readyStream, readyCont) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream()
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

            // Heartbeat is gated on the ready payload — mirror the reference
            // client instead of assuming.
            if ready.heartbeat {
                startHeartbeat(session)
            }
        } catch let error as TransportError {
            await teardown(connectionState == .open ? .normalClosure : .abnormalClosure, error: error)
            throw error
        } catch let error as AuthenticationError {
            // Auth material could not be produced (ticket mint failed / TTL
            // expired / loopback token missing). Classify explicitly; never
            // echo the raw credential (spec §29).
            let wrapped = TransportError.authenticationFailed(error.localizedDescription)
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
    }

    // MARK: P4 — replay hold

    /// Park inbound event frames for watermarked sessions until
    /// `endReplayHold()` is called. Used by the replay engine so a replayed
    /// `session.events.since` batch can be injected in order before live
    /// frames resume (spec §10 "park live frames during replay").
    public func beginReplayHold() {
        replayHoldActive = true
        replayHoldBuffer.removeAll()
    }

    /// Resume forwarding, flushing parked frames seq-gated: frames with
    /// seq ≤ the current watermark are dropped (dedupe against what replay
    /// already injected); the rest are forwarded in arrival order.
    public func endReplayHold() {
        replayHoldActive = false
        let held = replayHoldBuffer
        replayHoldBuffer.removeAll()
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
        sessionWatermarks[sessionID] = max(sessionWatermarks[sessionID] ?? 0, seq)
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

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, any Error>) in
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
                    await self.failPending(id: id, error: TransportError.transportFailure("send failed: \(error)"))
                }
            }
            // Timeout race: fail the pending continuation if no response
            // arrived within requestTimeout.
            Task { [weak self, config] in
                try? await Task.sleep(for: config.requestTimeout)
                await self?.failPending(id: id, error: TransportError.requestTimeout)
            }
        }
    }

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
        await setLastInbound()
        switch message {
        case .text(let line):
            await handleText(line)
        case .data:
            break // /api/ws is text-only; binary frames are ignored in P1
        }
    }

    private func setLastInbound() {
        lastInbound = clock.now
    }

    private func handleText(_ line: String) async {
        guard let decoded = try? JSONRPCCodec.decode(line) else {
            return // malformed frame: skip (parse-error tolerance per threat model)
        }
        switch decoded {
        case .event(let event):
            guard let gatewayEvent = GatewayEvent(event: event) else { return }
            await handleEvent(gatewayEvent)
        case .response(let response):
            // Correlate with a pending RPC request (M2: profiles.list /
            // session.list) by exact id. Unknown/duplicate ids are ignored —
            // a late response to a timed-out request must not crash.
            if let continuation = pendingRequests.removeValue(forKey: response.id) {
                continuation.resume(returning: response.result ?? .null)
            }
        case .error(let error):
            if let continuation = pendingRequests.removeValue(forKey: error.id) {
                continuation.resume(throwing: error.error)
            }
        case .request:
            break // server → client requests don't occur on this seam
        }
    }

    private func handleEvent(_ event: GatewayEvent) async {
        // P4 (M6): during a replay pass, park inbound event frames for
        // sessions instead of forwarding, so replayed events inject first.
        // `gateway.ready` has no session_id and always forwards (it is also
        // the only event routed to the ready channel).
        if replayHoldActive, event.sessionID != nil, event.seq != nil {
            replayHoldBuffer.append(event)
            return
        }
        forward(event, advanceWatermark: true)
        switch event.type {
        case .gatewayReady:
            let payload = event.ready ?? GatewayEvent.ReadyPayload(
                skin: nil, changeEvents: false, heartbeat: false, replayEpoch: nil)
            readyContinuation.yield(payload)
        case .error:
            // Surface transport-level error events; P1 just records them.
            break
        case .sessionInfo, .messageStart, .messageDelta, .messageInterim,
             .messageComplete, .thinkingDelta, .reasoningDelta,
             .reasoningAvailable, .statusUpdate, .toolStart, .toolGenerating,
             .toolProgress, .toolComplete, .backgroundComplete, .unknown:
            // Conversation/streaming events are forwarded via the event
            // channel above; the transport itself does not interpret them.
            break
        }
    }

    /// Yield one event to the live subscription channel and advance the
    /// session watermark (when `advanceWatermark` is true). Replayed events
    /// and live frames both pass through here so watermarks stay monotonic.
    private func forward(_ event: GatewayEvent, advanceWatermark: Bool) {
        eventContinuation.yield(event)
        if advanceWatermark, let sessionID = event.sessionID, let seq = event.seq {
            sessionWatermarks[sessionID] = max(sessionWatermarks[sessionID] ?? 0, seq)
        }
    }

    /// Subscribe to the gateway's inbound event stream (M5 conversation
    /// streaming). The returned stream yields every decoded `GatewayEvent` in
    /// arrival order and lives for the transport's lifetime (reconnects
    /// included). Single consumer: one conversation client per gateway.
    public nonisolated func subscribeToEvents() -> AsyncStream<GatewayEvent> {
        eventStream
    }

    // MARK: heartbeat

    private func startHeartbeat(_ session: any WebSocketSession) {
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            let interval = self.config.pingInterval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await self.sendPing(session)
                await self.checkInboundDeadline()
            }
        }
    }

    private func sendPing(_ session: any WebSocketSession) async {
        nextHeartbeatID += 1
        let id = JSONRPCID.string("heartbeat-\(nextHeartbeatID)")
        let frame = JSONRPCRequest(id: id, method: "gateway.ping", params: .object([:]))
        do {
            let line = try JSONRPCCodec.encode(.request(frame))
            try await session.send(.text(line))
        } catch {
            // Send failure will surface via the receive loop / close path.
        }
    }

    private func checkInboundDeadline() async {
        let deadline = config.inboundDeadline
        let elapsed = clock.now - lastInbound
        if elapsed > deadline {
            await teardown(.abnormalClosure, error: TransportError.connectionClosed(.abnormalClosure))
        }
    }

    // MARK: teardown

    private func handleReceiveFailure(_ error: any Error, for failedSession: any WebSocketSession) async {
        // Ignore a failure from a session that is no longer current — the
        // reconnect already replaced it and its own loop owns teardown (P4).
        guard let current = session, isSame(current, failedSession) else { return }
        // Prefer the close code captured by the delegate; fall back to error mapping.
        if let code = failedSession.lastCloseCode {
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
        // Idempotent: only the first teardown writes terminal state. Late
        // receive-loop failures (e.g. the socket error surfaced after we
        // already closed) must not clobber the classified reason.
        let wasTerminal: Bool
        switch connectionState {
        case .closed, .error: wasTerminal = true
        default: wasTerminal = false
        }
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
        // P4 (M6): finish the per-connection ready channel (waitForReady on
        // the closing connection must fail fast); the event channel is NOT
        // finished so a reconnecting client keeps its live subscription.
        readyContinuation.finish()
        lastDisconnectReason = reason
        await session?.close(code: 1000, reason: nil)
        session = nil
        replayHoldActive = false
        replayHoldBuffer.removeAll()
        guard !wasTerminal else { return }
        switch reason {
        case .normalClosure:
            connectionState = .closed
            stateBox.set(.disconnected)
        default:
            connectionState = .error(reason)
            stateBox.set(.failed(reason.debugDescription))
        }
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
        components.path = path
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
}
