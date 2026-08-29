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
        }
    }
}

/// Concrete `HermesTransport` for the Hermes gateway `/api/ws` WebSocket
/// JSON-RPC seam.
///
/// Lifecycle (P1 scope): mint ticket → open socket → receive `gateway.ready`
/// → adopt heartbeat flag + replay_epoch → run 15s ping / 45s inbound-deadline
/// heartbeat while open → map close codes to `DisconnectReason` on teardown.
/// Reconnect/replay (P4), conversation RPCs (P3), PTY (P5) are later
/// milestones and intentionally not implemented here.
public actor GatewayWebSocketTransport: HermesTransport {
    // MARK: configuration
    private let baseURL: URL
    private let ticketMinter: any WSTicketMinting
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

    // MARK: RPC correlation (M2)
    /// Requests awaiting a correlated response, keyed by request id.
    /// The receive loop resumes the matching continuation on `.response` /
    /// `.error`; teardown fails every pending request so callers never hang.
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextRequestID: Int = 0

    /// Ready-handshake channel: the receive loop yields `gateway.ready`
    /// payloads here; `waitForReady()` consumes the first one with a timeout.
    private let readyEvents: AsyncStream<GatewayEvent.ReadyPayload>
    private let readyContinuation: AsyncStream<GatewayEvent.ReadyPayload>.Continuation

    private let clock = ContinuousClock()

    public init(
        baseURL: URL,
        ticketMinter: any WSTicketMinting,
        sessionFactory: any WebSocketSessionFactory = URLSessionWebSocketSessionFactory(),
        configuration: TransportConfiguration = .standard,
        initialState: TransportState = .disconnected
    ) {
        self.baseURL = baseURL
        self.ticketMinter = ticketMinter
        self.sessionFactory = sessionFactory
        self.config = configuration
        self.stateBox = TransportStateBox(initialState)
        self.lastInbound = .now
        let (stream, continuation) = AsyncStream<GatewayEvent.ReadyPayload>.makeStream()
        self.readyEvents = stream
        self.readyContinuation = continuation
    }

    // MARK: HermesTransport

    public func connect() async throws {
        guard connectionState == .idle || connectionState == .closed else {
            throw TransportError.invalidState("connect() from \(connectionState)")
        }
        connectionState = .connecting
        stateBox.set(.connecting)

        do {
            let ticket = try await ticketMinter.mintTicket()
            guard let url = Self.buildWebSocketURL(base: baseURL, path: "/api/ws", ticket: ticket) else {
                throw TransportError.unableToBuildURL
            }
            let session = sessionFactory.makeSession(url: url)
            self.session = session

            lastInbound = clock.now
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
        } catch {
            let mapped = CloseCodeMapping.reason(for: error)
            await teardown(mapped, error: TransportError.connectionClosed(mapped))
            throw TransportError.connectionClosed(mapped)
        }
    }

    public func disconnect() async {
        await teardown(.normalClosure, error: nil)
    }

    // MARK: RPC request/response (M2 — roster RPCs)

    /// Send a JSON-RPC request and await the correlated response/error.
    ///
    /// M2 uses this for `profiles.list` / `session.list` (roster RPCs).
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
        try await withThrowingTaskGroup(of: GatewayEvent.ReadyPayload.self) { group in
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
                await self.handleReceiveFailure(error)
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
        switch event.type {
        case .gatewayReady:
            let payload = event.ready ?? GatewayEvent.ReadyPayload(
                skin: nil, changeEvents: false, heartbeat: false, replayEpoch: nil)
            readyContinuation.yield(payload)
        case .error:
            // Surface transport-level error events; P1 just records them.
            break
        case .unknown:
            break
        }
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

    private func handleReceiveFailure(_ error: any Error) async {
        // Prefer the close code captured by the delegate; fall back to error mapping.
        if let code = session?.lastCloseCode {
            let reason = CloseCodeMapping.reason(forRawCode: code)
            await teardown(reason, error: TransportError.connectionClosed(reason))
        } else {
            let reason = CloseCodeMapping.reason(for: error)
            await teardown(reason, error: TransportError.connectionClosed(reason))
        }
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
        readyContinuation.finish()
        await session?.close(code: 1000, reason: nil)
        session = nil
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

    /// Build `ws(s)://host:port/api/ws?ticket=...` from a base `http(s)://`
    /// origin, matching `buildHermesWebSocketUrl`.
    public static func buildWebSocketURL(base: URL, path: String, ticket: WSTicket) -> URL? {
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
        query.append(ticket.authQueryItem)
        components.queryItems = query
        return components.url
    }
}
