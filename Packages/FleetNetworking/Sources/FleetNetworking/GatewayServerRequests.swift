import Foundation
import os
import FleetCore

/// What the gateway said about server→client requests on the current
/// connection (the outcome of `client.capabilities {server_requests: true}`).
public enum ServerRequestSupport: Sendable, Equatable {
    /// This transport does not advertise (it has no prompt UI behind it), or
    /// the connection is down.
    case notAdvertised
    /// Advertised; the gateway has not answered yet.
    case pending
    /// The gateway may send these request methods
    /// (`client.capabilities` result `server_requests`).
    case acknowledged(methods: [String])
    /// The gateway answered with an error: an older build that has no
    /// server→client requests. The legacy `approval.request` event path
    /// applies and no request-based prompt is promised.
    case refused
}

// MARK: - Decoding (wire -> domain)

/// P0.1 — decode one server→client JSON-RPC request (or one `open_requests`
/// entry) into the FleetCore `ServerRequest` vocabulary.
///
/// Shapes verified against `tui_gateway/server_requests.py` (`frame()` /
/// `snapshot()`) and the OpenRPC contract's `x-server-requests`:
/// `params` is `{session_id, ...method-specific}` and, on a reconnect replay,
/// a clarify request may also carry `answers` (locks the server already
/// accepted).
enum GatewayServerRequestDecoder {
    /// - Returns: the request, or the JSON-RPC error to answer it with:
    ///   `-32601` for a method Fleet does not implement (so the agent fails
    ///   fast instead of waiting out its deadline) and `-32602` for a
    ///   supported method whose params cannot be rendered/answered safely.
    static func decode(
        id: JSONRPCID,
        method: String,
        params: JSONValue?,
        replayed: Bool
    ) -> Result<ServerRequest, JSONRPCError> {
        guard ServerRequestMethod.supported.contains(method) else {
            return .failure(JSONRPCError(
                code: JSONRPCError.methodNotFound.code,
                message: "no handler for server request: \(method)"))
        }
        guard let object = params?.objectValue,
              let sessionID = object["session_id"]?.stringValue,
              RoutingGuard.isValidSessionKey(sessionID) else {
            return .failure(invalid("\(method) request needs a valid session_id"))
        }
        let requestID = id.wireValue
        switch method {
        case ServerRequestMethod.approval:
            guard let approvalID = object["request_id"]?.stringValue, !approvalID.isEmpty else {
                return .failure(invalid("approval request missing request_id"))
            }
            let approval = ApprovalRequest(
                requestID: approvalID,
                sessionID: sessionID,
                command: object["command"]?.stringValue ?? "",
                detail: object["description"]?.stringValue,
                choices: object["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                serverRequestID: requestID
            )
            return .success(ServerRequest(
                id: requestID, sessionID: sessionID, kind: .approval(approval), replayed: replayed))

        case ServerRequestMethod.clarify:
            guard let prompt = decodeClarify(object, sessionID: sessionID) else {
                return .failure(invalid("clarify request has no question"))
            }
            return .success(ServerRequest(
                id: requestID, sessionID: sessionID, kind: .clarify(prompt), replayed: replayed))

        case ServerRequestMethod.sudo:
            let prompt = SudoPrompt(sessionID: sessionID, command: object["command"]?.stringValue ?? "")
            return .success(ServerRequest(
                id: requestID, sessionID: sessionID, kind: .sudo(prompt), replayed: replayed))

        default: // ServerRequestMethod.secret
            guard let envVar = object["env_var"]?.stringValue, !envVar.isEmpty else {
                return .failure(invalid("secret request missing env_var"))
            }
            let prompt = SecretPrompt(
                sessionID: sessionID,
                envVar: envVar,
                prompt: object["prompt"]?.stringValue ?? "")
            return .success(ServerRequest(
                id: requestID, sessionID: sessionID, kind: .secret(prompt), replayed: replayed))
        }
    }

    private static func invalid(_ message: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCError.invalidParams.code, message: message)
    }

    private static func decodeClarify(_ object: [String: JSONValue], sessionID: String) -> ClarifyPrompt? {
        let locked = (object["answers"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        if let rows = object["questions"]?.arrayValue, !rows.isEmpty {
            var questions: [ClarifyQuestion] = []
            for row in rows {
                guard let entry = row.objectValue,
                      let qid = entry["qid"]?.stringValue, !qid.isEmpty,
                      let text = entry["question"]?.stringValue else { return nil }
                questions.append(ClarifyQuestion(
                    qid: qid,
                    question: text,
                    choices: entry["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    multiSelect: entry["multi_select"]?.boolValue ?? false))
            }
            return ClarifyPrompt(sessionID: sessionID, questions: questions, isBatch: true, lockedAnswers: locked)
        }
        guard let text = object["question"]?.stringValue, !text.isEmpty else { return nil }
        let question = ClarifyQuestion(
            qid: "",
            question: text,
            choices: object["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            multiSelect: object["multi_select"]?.boolValue ?? false)
        return ClarifyPrompt(sessionID: sessionID, questions: [question], isBatch: false, lockedAnswers: [:])
    }

    /// Decode the `open_requests` array of a `session.resume` /
    /// `session.activate` / `session.events.since` result. Entries are
    /// `{id, method, params}` (`ServerRequest.snapshot`). Returns the wire
    /// entries (id preserved) so the transport can answer an undecodable one
    /// with the right error.
    static func openRequestEntries(in result: JSONValue) -> [(id: JSONRPCID, method: String, params: JSONValue?)] {
        guard let rows = result["open_requests"]?.arrayValue else { return [] }
        return rows.compactMap { row in
            guard let entry = row.objectValue,
                  let id = entry["id"]?.stringValue, !id.isEmpty,
                  let method = entry["method"]?.stringValue else { return nil }
            return (.string(id), method, entry["params"])
        }
    }
}

// MARK: - Open-request registry

/// The transport's registry of server→client requests that are open right now
/// (received and not yet answered / cancelled), plus the live subscribers.
///
/// It exists so a request is never lost to timing: one that arrives before a
/// conversation screen subscribes is replayed to that screen when it does
/// (the gateway keeps waiting for a client, so answering it with an error
/// would withdraw a prompt nobody has seen yet). The lock makes
/// "snapshot the open set and register the subscriber" atomic, so a request
/// can neither be missed nor delivered twice around a subscribe.
final class ServerRequestBox: @unchecked Sendable {
    struct Open: Sendable {
        let wireID: JSONRPCID
        let request: ServerRequest
    }

    private struct State {
        var open: [Open] = []
        var subscribers: [UUID: AsyncStream<ServerRequest>.Continuation] = [:]
        var conversationSubscribers: [UUID: BoundedQueue<ConversationEvent>] = [:]
        /// Ids answered locally or withdrawn by the gateway, newest last.
        /// A stale `open_requests` snapshot that races the settlement must not
        /// resurrect a prompt the user already answered or the gateway cancelled.
        var settled: [String] = []
    }

    /// Bound on simultaneously open requests: a wedged or hostile peer cannot
    /// grow the registry without limit.
    static let maxOpen = 32
    private static let maxSettled = 128

    private let lock = OSAllocatedUnfairLock(initialState: State())
    /// Called (outside the lock's hot path) for every conversation event the
    /// bounded subscriber queues had to evict.
    private let onGap: @Sendable (EventGap) -> Void

    init(onGap: @escaping @Sendable (EventGap) -> Void = { _ in }) {
        self.onGap = onGap
    }

    enum Admission: Sendable {
        case admitted
        /// Already open under this id (a re-delivery over the same socket).
        case duplicate
        /// Answered / withdrawn already; ignore the stale re-delivery.
        case settled
        case full
    }

    /// Record an open request and deliver it to every subscriber.
    func admit(_ open: Open) -> Admission {
        let (admission, evicted): (Admission, [BoundedQueue<ConversationEvent>.Entry]) = lock.withLock { state in
            let id = open.request.id
            if state.settled.contains(id) { return (.settled, []) }
            if state.open.contains(where: { $0.request.id == id }) { return (.duplicate, []) }
            guard state.open.count < Self.maxOpen else { return (.full, []) }
            state.open.append(open)
            for continuation in state.subscribers.values {
                continuation.yield(open.request)
            }
            var evictedEntries: [BoundedQueue<ConversationEvent>.Entry] = []
            for queue in state.conversationSubscribers.values {
                // Pinned: an approval prompt is not evicted for overflow, but
                // admitting it may evict an older ordinary event: report it.
                evictedEntries += queue.push(.init(value: .serverRequest(open.request), bytes: 256,
                                                   sessionID: open.request.sessionID, pinned: true))
            }
            return (.admitted, evictedEntries)
        }
        for e in evicted { onGap(EventGap(sessionID: e.sessionID, reason: .subscriberOverflow)) }
        return admission
    }

    /// Atomically register a subscriber and hand it the currently open
    /// requests (marked replayed) before any live one.
    func subscribe(_ continuation: AsyncStream<ServerRequest>.Continuation) -> UUID {
        let token = UUID()
        lock.withLock { state in
            for open in state.open {
                let r = open.request
                continuation.yield(ServerRequest(id: r.id, sessionID: r.sessionID, kind: r.kind, replayed: true))
            }
            state.subscribers[token] = continuation
        }
        return token
    }

    /// Requests and withdrawals share one ordered stream. Merging two
    /// independent tasks can deliver a withdrawal before its request.
    func subscribeConversation(maxCount: Int, maxBytes: Int) -> (token: UUID, queue: BoundedQueue<ConversationEvent>) {
        let token = UUID()
        let queue = BoundedQueue<ConversationEvent>(maxCount: maxCount, maxBytes: maxBytes)
        lock.withLock { state in
            for open in state.open {
                let r = open.request
                queue.push(.init(value: .serverRequest(ServerRequest(
                    id: r.id, sessionID: r.sessionID, kind: r.kind, replayed: true)),
                                 bytes: 256, sessionID: r.sessionID, pinned: true))
            }
            state.conversationSubscribers[token] = queue
        }
        return (token, queue)
    }

    func unsubscribeConversation(_ token: UUID) {
        let queue = lock.withLock { $0.conversationSubscribers.removeValue(forKey: token) }
        queue?.finish()
    }

    func forwardConversation(_ event: GatewayEvent, bytes: Int) {
        guard let decoded = GatewayConversationClient.decodeEvent(event) else { return }
        let pinned = event.type == .requestCancel || event.type == .approvalRequest
        let queues = lock.withLock { Array($0.conversationSubscribers.values) }
        let entry = BoundedQueue<ConversationEvent>.Entry(
            value: decoded, bytes: bytes, sessionID: event.sessionID, pinned: pinned)
        var evicted: [BoundedQueue<ConversationEvent>.Entry] = []
        for queue in queues { evicted += queue.push(entry) }
        // Aggregate budget across conversation subscribers.
        var total = queues.reduce(0) { $0 + $1.byteCount }
        var aggregate: [BoundedQueue<ConversationEvent>.Entry] = []
        while total > GatewayEventBudget.maxAggregateBufferedBytes,
              let largest = queues.max(by: { $0.byteCount < $1.byteCount }),
              largest.count > 1, let dropped = largest.dropOldest() {
            total -= dropped.bytes
            aggregate.append(dropped)
        }
        for e in evicted { onGap(EventGap(sessionID: e.sessionID, reason: .subscriberOverflow)) }
        for e in aggregate { onGap(EventGap(sessionID: e.sessionID, reason: .aggregateOverflow)) }
    }

    func unsubscribe(_ token: UUID) {
        lock.withLock { _ = $0.subscribers.removeValue(forKey: token) }
    }

    func wireID(for id: String) -> JSONRPCID? {
        lock.withLock { state in state.open.first(where: { $0.request.id == id })?.wireID }
    }

    /// Whether this id was already answered / withdrawn.
    func isSettled(_ id: String) -> Bool {
        lock.withLock { $0.settled.contains(id) }
    }

    /// Remove `id` from the open set and remember it as settled. Returns
    /// whether it was open.
    @discardableResult
    func settle(_ id: String) -> Bool {
        lock.withLock { state in
            let wasOpen = state.open.contains(where: { $0.request.id == id })
            state.open.removeAll { $0.request.id == id }
            if !state.settled.contains(id) {
                state.settled.append(id)
                if state.settled.count > Self.maxSettled {
                    state.settled.removeFirst(state.settled.count - Self.maxSettled)
                }
            }
            return wasOpen
        }
    }

    /// The connection ended. The gateway keeps its requests open and
    /// re-delivers them through `open_requests` on resume, so the registry is
    /// emptied rather than left holding prompts the next connection may not have.
    func clearOpen() {
        lock.withLock { $0.open.removeAll() }
    }

    var openCount: Int { lock.withLock { $0.open.count } }
}

// MARK: - Answering (domain seam over the transport)

/// Concrete `ServerPromptResponding` over the conversation transport.
///
/// Wire ground truth (`tui_gateway/server_requests.py`,
/// `tui_gateway/methods_prompt.py`, OpenRPC contract):
/// - `clarify` single: response `{answer}`; `''` means skipped.
/// - `clarify` batch: one `clarify.lock {request_id, question_id, answer}` per
///   question (`request_id` is the request's `srq-` id); the lock that empties
///   `remaining` resolves the request. A response with no `answers` is
///   cancel-all.
/// - `sudo` / `secret`: response `{value}`; `''` means skipped / declined.
///
/// Secrecy: `answerValue` forwards the value into ONE response frame and
/// keeps nothing. Nothing here logs a value, and errors are mapped through
/// `Redaction` without echoing request content.
public struct GatewayServerPromptClient: ServerPromptResponding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "server-prompt-client")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    public func answerClarify(requestID: String, answer: String) async throws {
        try await respond(requestID: requestID, result: .object(["answer": .string(answer)]))
    }

    public func lockClarifyAnswer(
        requestID: String, questionID: String, answer: String
    ) async throws -> ClarifyLockStatus {
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object([
            "request_id": .string(requestID),
            "question_id": .string(questionID),
            "answer": .string(answer),
        ])
        do {
            let result = try await transport.request(method: "clarify.lock", params: params)
            switch result["status"]?.stringValue {
            case "ok":
                let remaining = result["remaining"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if remaining.isEmpty {
                    // The last lock resolved the request server-side.
                    await transport.settleServerRequest(id: requestID)
                }
                return .locked(remaining: remaining)
            case "expired":
                await transport.settleServerRequest(id: requestID)
                return .expired
            default:
                throw ConversationError.malformedPayload("clarify.lock result missing 'status'")
            }
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw GatewayApprovalClient.mapError(error)
        } catch let error as TransportError {
            throw GatewayApprovalClient.mapTransportError(error)
        }
    }

    public func cancelClarify(requestID: String) async throws {
        try await respond(requestID: requestID, result: .object([:]))
    }

    public func answerValue(requestID: String, value: String) async throws {
        try await respond(requestID: requestID, result: .object(["value": .string(value)]))
    }

    private func respond(requestID: String, result: JSONValue) async throws {
        do {
            try await transport.respondToServerRequest(id: requestID, result: result)
        } catch let error as TransportError {
            throw GatewayApprovalClient.mapTransportError(error)
        }
    }
}
