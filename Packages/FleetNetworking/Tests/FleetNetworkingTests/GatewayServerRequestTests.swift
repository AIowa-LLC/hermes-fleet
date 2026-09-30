import XCTest
import FleetCore
@testable import FleetNetworking

/// P0.1: server→client JSON-RPC requests (`approval`, `clarify`, `sudo`,
/// `secret`), `request.cancel`, `open_requests` on resume / `events.since`,
/// and the `client.capabilities {server_requests: true}` advertisement.
///
/// Fixtures are synthetic and mirror the contract shapes of upstream
/// `tui_gateway/server_requests.py` (`ServerRequest.frame()` / `snapshot()`)
/// and the OpenRPC contract (`x-server-requests`, `x-notifications`
/// `request.cancel`, `OpenRequestEntry`). Request ids are `srq-<hex>` strings
/// that never collide with the client's `rpc-N` ids.
final class GatewayServerRequestTests: XCTestCase {

    // MARK: helpers

    private let sid = "abc12345"

    private func makeTransport(
        serverPort: UInt16, advertises: Bool = true
    ) -> GatewayWebSocketTransport {
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(5),
            requestTimeout: .seconds(3),
            advertisesServerRequests: advertises
        )
        return GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(serverPort)")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func ready() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private static func requestFrame(id: String, method: String, params: [String: Any]) -> String {
        json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func eventFrame(type: String, sessionID: String, payload: [String: Any], seq: Int? = nil) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID, "payload": payload]
        if let seq { params["seq"] = seq }
        return json(["jsonrpc": "2.0", "method": "event", "params": params])
    }

    private func approvalParams(requestID: String = "req-0001") -> [String: Any] {
        [
            "session_id": sid,
            "request_id": requestID,
            "command": "printf 'fixture operation'",
            "description": "Synthetic dangerous command",
            "choices": ["once", "session", "always", "deny"],
            "allow_session": true,
            "allow_permanent": true,
        ]
    }

    /// Records every frame the client sends to the fixture gateway.
    private final class FrameRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [[String: Any]] = []
        var frames: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return _frames
        }
        func record(_ raw: String) {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.lock(); defer { lock.unlock() }
            _frames.append(object)
        }
        func methods() -> [String] { frames.compactMap { $0["method"] as? String } }
        func responses(toID id: String) -> [[String: Any]] {
            frames.filter { ($0["id"] as? String) == id && $0["method"] == nil }
        }
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func next(
        _ stream: AsyncStream<ServerRequest>, timeout: Duration = .seconds(3)
    ) async -> ServerRequest? {
        await withTaskGroup(of: ServerRequest?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func expectNext(
        _ stream: AsyncStream<ServerRequest>, timeout: Duration = .seconds(3)
    ) async throws -> ServerRequest {
        let request = await next(stream, timeout: timeout)
        return try XCTUnwrap(request, "no server request arrived")
    }

    private func assertNoNext(
        _ stream: AsyncStream<ServerRequest>, timeout: Duration, _ message: String
    ) async {
        let request = await next(stream, timeout: timeout)
        XCTAssertNil(request, message)
    }

    private func startServer(
        onOpen: [String] = [GatewayServerRequestTests.ready()],
        recorder: FrameRecorder,
        reply: @escaping @Sendable (String) -> [String] = { _ in [] }
    ) async throws -> InProcessWebSocketServer {
        let server = try InProcessWebSocketServer(script: .init(
            onOpen: onOpen,
            onText: { frame in
                recorder.record(frame)
                return reply(frame)
            }))
        try await server.start()
        return server
    }

    private static func idAndMethod(_ frame: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else { return nil }
        return (id, method, object["params"] as? [String: Any] ?? [:])
    }

    // MARK: 1. capability advertisement

    func testAdvertisesServerRequestsOncePerConnectionAfterReady() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)

        try await transport.connect()
        try await waitUntil("client.capabilities") { recorder.methods().contains("client.capabilities") }

        let capabilityFrames = recorder.frames.filter { ($0["method"] as? String) == "client.capabilities" }
        XCTAssertEqual(capabilityFrames.count, 1)
        let frame = try XCTUnwrap(capabilityFrames.first)
        XCTAssertEqual(frame["jsonrpc"] as? String, "2.0")
        XCTAssertEqual((frame["params"] as? [String: Any])?["server_requests"] as? Bool, true)
        let id = try XCTUnwrap(frame["id"] as? String)
        XCTAssertFalse(id.hasPrefix("rpc-"), "must not collide with correlated client request ids")
        await transport.disconnect()
    }

    func testAdvertisesAgainOnEveryReconnect() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)

        try await transport.connect()
        try await waitUntil("first advertisement") {
            recorder.methods().filter { $0 == "client.capabilities" }.count == 1
        }
        server.abortConnection()
        try await waitUntil("failed state") { transport.state != .connected }
        try await transport.connect()
        try await waitUntil("second advertisement") {
            recorder.methods().filter { $0 == "client.capabilities" }.count == 2
        }
        await transport.disconnect()
    }

    func testOlderGatewayRefusingCapabilitiesDoesNotBreakTheConnection() async throws {
        // A gateway that predates `client.capabilities` answers -32601. That is
        // not a failure of the connection, and no request-based UI is promised.
        let recorder = FrameRecorder()
        let server = try await startServer(recorder: recorder) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "client.capabilities" else { return [] }
            return [Self.json(["jsonrpc": "2.0", "id": id,
                               "error": ["code": -32601, "message": "unknown method: client.capabilities"]])]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)

        try await transport.connect()
        try await waitUntil("client.capabilities") { recorder.methods().contains("client.capabilities") }
        var support = await transport.serverRequestSupport()
        for _ in 0..<100 where support != .refused {
            try await Task.sleep(for: .milliseconds(20))
            support = await transport.serverRequestSupport()
        }
        XCTAssertEqual(support, .refused)
        XCTAssertEqual(transport.state, .connected)
        await transport.disconnect()
    }

    func testCapabilitiesResultIsRecordedAsSupportedMethods() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(recorder: recorder) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "client.capabilities" else { return [] }
            return [Self.responseFrame(id: id, result: ["server_requests": ["approval", "clarify", "sudo", "secret"]])]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        var support = await transport.serverRequestSupport()
        for _ in 0..<100 {
            if case .acknowledged = support { break }
            try await Task.sleep(for: .milliseconds(20))
            support = await transport.serverRequestSupport()
        }
        XCTAssertEqual(support, .acknowledged(methods: ["approval", "clarify", "sudo", "secret"]))
        await transport.disconnect()
        let afterDisconnect = await transport.serverRequestSupport()
        XCTAssertEqual(afterDisconnect, .notAdvertised, "the verdict belongs to one connection")
    }

    func testTransportWithoutAUIDoesNotAdvertise() async throws {
        // Only the conversation transport opts in: an unanswerable prompt
        // must fail fast at the gateway rather than park.
        let recorder = FrameRecorder()
        let server = try await startServer(recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort, advertises: false)
        try await transport.connect()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(recorder.methods().contains("client.capabilities"))
        let support = await transport.serverRequestSupport()
        XCTAssertEqual(support, .notAdvertised)
        XCTAssertFalse(TransportConfiguration.standard.advertisesServerRequests)
        XCTAssertTrue(TransportConfiguration.conversation.advertisesServerRequests)
        await transport.disconnect()
    }

    // MARK: 2. approval as a server request

    func testApprovalServerRequestDecodesAndIsAnsweredWithAJSONRPCResponse() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-fixture01", method: "approval", params: approvalParams())],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()

        let request = try await expectNext(stream)
        XCTAssertEqual(request.id, "srq-fixture01")
        XCTAssertEqual(request.sessionID, sid)
        XCTAssertFalse(request.replayed)
        guard case .approval(let approval) = request.kind else { return XCTFail("expected approval kind") }
        XCTAssertEqual(approval.requestID, "req-0001")
        XCTAssertEqual(approval.serverRequestID, "srq-fixture01")
        XCTAssertEqual(approval.command, "printf 'fixture operation'")
        XCTAssertEqual(approval.detail, "Synthetic dangerous command")
        XCTAssertEqual(approval.choices, ["once", "session", "always", "deny"])

        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let resolved = try await client.respond(to: approval, choice: .session, all: false)
        XCTAssertEqual(resolved, 1)

        try await waitUntil("approval response") { !recorder.responses(toID: "srq-fixture01").isEmpty }
        let responses = recorder.responses(toID: "srq-fixture01")
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0]["jsonrpc"] as? String, "2.0")
        let result = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        XCTAssertEqual(result["choice"] as? String, "session")
        XCTAssertNil(result["all"], "`all` is only sent when true")
        XCTAssertFalse(recorder.methods().contains("approval.respond"),
                       "a server-request approval must not fall back to the legacy method")
        await transport.disconnect()
    }

    func testApprovalAnswerIsIdempotentPerRequestID() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-fixture01", method: "approval", params: approvalParams())],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let request = try await expectNext(stream)
        guard case .approval(let approval) = request.kind else { return XCTFail("expected approval kind") }

        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.respond(to: approval, choice: .deny, all: true)
        _ = try await client.respond(to: approval, choice: .once, all: false)

        try await waitUntil("first response") { !recorder.responses(toID: "srq-fixture01").isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        let responses = recorder.responses(toID: "srq-fixture01")
        XCTAssertEqual(responses.count, 1, "a stale card answering twice is a no-op on the wire")
        let result = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        XCTAssertEqual(result["choice"] as? String, "deny")
        XCTAssertEqual(result["all"] as? Bool, true)
        await transport.disconnect()
    }

    func testLegacyApprovalRequestStillAnswersViaApprovalRespond() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(recorder: recorder) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "approval.respond" else { return [] }
            return [Self.responseFrame(id: id, result: ["resolved": 1])]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        let legacy = ApprovalRequest(requestID: "req-legacy", sessionID: sid, command: "true", choices: ["once", "deny"])
        XCTAssertNil(legacy.serverRequestID)
        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let resolved = try await client.respond(to: legacy, choice: .once, all: false)

        XCTAssertEqual(resolved, 1)
        let call = try XCTUnwrap(recorder.frames.first { ($0["method"] as? String) == "approval.respond" })
        let params = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "req-legacy")
        XCTAssertEqual(params["choice"] as? String, "once")
        await transport.disconnect()
    }

    func testLegacyApprovalRequestEventDecodingIsUnchanged() {
        let event = GatewayEvent(
            type: .approvalRequest, rawType: "approval.request", sessionID: sid, seq: 4,
            payload: .object(["request_id": .string("req-legacy"), "command": .string("true"),
                              "choices": .array([.string("once"), .string("deny")])]))
        guard case .approvalRequested(let decodedSID, let requestID, _, _, let choices, let seq)? =
                GatewayConversationClient.decodeEvent(event) else {
            return XCTFail("legacy approval.request must still decode")
        }
        XCTAssertEqual(decodedSID, sid)
        XCTAssertEqual(requestID, "req-legacy")
        XCTAssertEqual(choices, ["once", "deny"])
        XCTAssertEqual(seq, 4)
    }

    // MARK: 3. clarify

    func testSingleClarifyDecodesAndAnswersWithAnswerResult() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-clarify01", method: "clarify", params: [
                        "session_id": sid, "question": "Which branch?",
                        "choices": ["main", "dev"], "multi_select": true])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()

        let request = try await expectNext(stream)
        guard case .clarify(let prompt) = request.kind else { return XCTFail("expected clarify kind") }
        XCTAssertFalse(prompt.isBatch)
        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions[0].question, "Which branch?")
        XCTAssertEqual(prompt.questions[0].choices, ["main", "dev"])
        XCTAssertTrue(prompt.questions[0].multiSelect)

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        try await client.answerClarify(requestID: request.id, answer: ClarifyAnswerEncoding.multiSelect(["main", "dev"]))
        try await waitUntil("clarify response") { !recorder.responses(toID: "srq-clarify01").isEmpty }
        let result = try XCTUnwrap(recorder.responses(toID: "srq-clarify01")[0]["result"] as? [String: Any])
        XCTAssertEqual(result["answer"] as? String, #"["main","dev"]"#)
        await transport.disconnect()
    }

    func testBatchClarifyLocksThroughClarifyLockRPCAndLastLockSettlesTheRequest() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-batch001", method: "clarify", params: [
                        "session_id": sid,
                        "questions": [
                            ["qid": "q1", "question": "First?", "choices": ["a", "b"], "multi_select": false],
                            ["qid": "q2", "question": "Second?", "choices": NSNull(), "multi_select": false],
                        ],
                        "answers": ["q1": "a"]])],
            recorder: recorder
        ) { frame in
            guard let (id, method, params) = Self.idAndMethod(frame), method == "clarify.lock" else { return [] }
            let remaining: [String] = (params["question_id"] as? String) == "q1" ? ["q2"] : []
            return [Self.responseFrame(id: id, result: ["status": "ok", "remaining": remaining])]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()

        let request = try await expectNext(stream)
        guard case .clarify(let prompt) = request.kind else { return XCTFail("expected clarify kind") }
        XCTAssertTrue(prompt.isBatch)
        XCTAssertEqual(prompt.questions.map(\.qid), ["q1", "q2"])
        XCTAssertEqual(prompt.questions[1].choices, [])
        XCTAssertEqual(prompt.lockedAnswers, ["q1": "a"], "replayed locks restore the checked state")

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let first = try await client.lockClarifyAnswer(requestID: request.id, questionID: "q1", answer: "b")
        XCTAssertEqual(first, .locked(remaining: ["q2"]))
        XCTAssertEqual(transport.openServerRequestCount, 1, "not settled until the last lock")
        let last = try await client.lockClarifyAnswer(requestID: request.id, questionID: "q2", answer: "free text")
        XCTAssertEqual(last, .locked(remaining: []))
        XCTAssertEqual(transport.openServerRequestCount, 0, "the last lock resolves the request server-side")

        let locks = recorder.frames.filter { ($0["method"] as? String) == "clarify.lock" }
        XCTAssertEqual(locks.count, 2)
        let params = try XCTUnwrap(locks[0]["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "srq-batch001", "request_id is the request's srq id")
        XCTAssertEqual(params["question_id"] as? String, "q1")
        XCTAssertEqual(params["answer"] as? String, "b")
        await transport.disconnect()
    }

    func testClarifyLockExpiredIsNotAnErrorAndDismissesTheRequest() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-batch002", method: "clarify", params: [
                        "session_id": sid,
                        "questions": [["qid": "q1", "question": "First?"]]])],
            recorder: recorder
        ) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "clarify.lock" else { return [] }
            return [Self.responseFrame(id: id, result: ["status": "expired"])]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let request = try await expectNext(stream)

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let status = try await client.lockClarifyAnswer(requestID: request.id, questionID: "q1", answer: "x")
        XCTAssertEqual(status, .expired)
        XCTAssertEqual(transport.openServerRequestCount, 0)
        await transport.disconnect()
    }

    func testCancelClarifyAnswersWithAnEmptyResult() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-batch003", method: "clarify", params: [
                        "session_id": sid,
                        "questions": [["qid": "q1", "question": "First?"]]])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let request = try await expectNext(stream)

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        try await client.cancelClarify(requestID: request.id)
        try await waitUntil("cancel-all response") { !recorder.responses(toID: "srq-batch003").isEmpty }
        let result = try XCTUnwrap(recorder.responses(toID: "srq-batch003")[0]["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty, "a response with no answers is cancel-all")
        await transport.disconnect()
    }

    // MARK: 4. sudo / secret

    func testSudoAndSecretDecodeAndAnswerWithValueResult() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-sudo0001", method: "sudo",
                                       params: ["session_id": sid, "command": "sudo true"]),
                     Self.requestFrame(id: "srq-secret01", method: "secret",
                                       params: ["session_id": sid, "env_var": "FIXTURE_API_KEY",
                                                "prompt": "Enter the fixture key", "metadata": ["skill": "fixture"]])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()

        let sudo = try await expectNext(stream)
        guard case .sudo(let sudoPrompt) = sudo.kind else { return XCTFail("expected sudo kind") }
        XCTAssertEqual(sudoPrompt.command, "sudo true")
        let secretRequest = try await expectNext(stream)
        guard case .secret(let secretPrompt) = secretRequest.kind else { return XCTFail("expected secret kind") }
        XCTAssertEqual(secretPrompt.envVar, "FIXTURE_API_KEY")
        XCTAssertEqual(secretPrompt.prompt, "Enter the fixture key")

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        // Synthetic value assembled at runtime so no scanner mistakes it for a credential.
        let fixtureValue = ["fixture", "entry", "value"].joined(separator: "-")
        try await client.answerValue(requestID: sudo.id, value: fixtureValue)
        try await client.answerValue(requestID: secretRequest.id, value: "")

        try await waitUntil("value responses") {
            !recorder.responses(toID: "srq-sudo0001").isEmpty && !recorder.responses(toID: "srq-secret01").isEmpty
        }
        let sudoResult = try XCTUnwrap(recorder.responses(toID: "srq-sudo0001")[0]["result"] as? [String: Any])
        XCTAssertEqual(sudoResult["value"] as? String, fixtureValue)
        let secretResult = try XCTUnwrap(recorder.responses(toID: "srq-secret01")[0]["result"] as? [String: Any])
        XCTAssertEqual(secretResult["value"] as? String, "", "an empty value means skipped / declined")
        await transport.disconnect()
    }

    // MARK: 5. unknown / malformed requests

    func testUnknownServerRequestMethodsAreAnsweredWithMethodNotFound() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-vault001", method: "vault.code", params: ["session_id": sid]),
                     Self.requestFrame(id: "srq-preview1", method: "preview.act", params: ["session_id": sid]),
                     Self.requestFrame(id: "srq-future01", method: "not.a.real.method", params: [:])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()

        for id in ["srq-vault001", "srq-preview1", "srq-future01"] {
            try await waitUntil("error for \(id)") { !recorder.responses(toID: id).isEmpty }
            let error = try XCTUnwrap(recorder.responses(toID: id)[0]["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32601, "\(id) must fail fast with method-not-found")
            XCTAssertNil(recorder.responses(toID: id)[0]["result"])
        }
        await assertNoNext(stream, timeout: .milliseconds(200), "unsupported methods never reach the UI")
        XCTAssertEqual(transport.openServerRequestCount, 0)
        await transport.disconnect()
    }

    func testSupportedMethodWithUnusableParamsIsAnsweredWithInvalidParams() async throws {
        let recorder = FrameRecorder()
        var noRequestID = approvalParams()
        noRequestID.removeValue(forKey: "request_id")
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-noreqid1", method: "approval", params: noRequestID),
                     Self.requestFrame(id: "srq-nosess01", method: "clarify", params: ["question": "Hi?"]),
                     Self.requestFrame(id: "srq-badsess1", method: "sudo", params: ["session_id": "../evil"])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        for id in ["srq-noreqid1", "srq-nosess01", "srq-badsess1"] {
            try await waitUntil("error for \(id)") { !recorder.responses(toID: id).isEmpty }
            let error = try XCTUnwrap(recorder.responses(toID: id)[0]["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
        }
        XCTAssertEqual(transport.openServerRequestCount, 0)
        await transport.disconnect()
    }

    func testNumericRequestIDIsEchoedAsANumber() async throws {
        let recorder = FrameRecorder()
        let numeric = #"{"jsonrpc":"2.0","id":7,"method":"sudo","params":{"session_id":"abc12345","command":"true"}}"#
        let server = try await startServer(onOpen: [Self.ready(), numeric], recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let request = try await expectNext(stream)
        XCTAssertEqual(request.id, "7")

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        try await client.answerValue(requestID: request.id, value: "")
        try await waitUntil("numeric-id response") {
            recorder.frames.contains { ($0["id"] as? Int) == 7 && $0["result"] != nil }
        }
        await transport.disconnect()
    }

    // MARK: 6. request.cancel

    func testRequestCancelDismissesThePromptAndNeverSendsAnAnswer() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-fixture01", method: "approval", params: approvalParams())],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let conversation = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let events = conversation.events
        try await transport.connect()

        var approval: ApprovalRequest?
        var cancelled: ConversationEvent?
        var iterator = events.makeAsyncIterator()
        // 1) the request surfaces on the conversation stream
        while approval == nil, let event = await iterator.next() {
            if case .serverRequest(let request) = event, case .approval(let a) = request.kind { approval = a }
        }
        XCTAssertEqual(approval?.serverRequestID, "srq-fixture01")

        // 2) the gateway withdraws it
        server.sendText(Self.eventFrame(
            type: "request.cancel", sessionID: sid,
            payload: ["id": "srq-fixture01", "method": "approval", "reason": "timeout"], seq: 9))
        while cancelled == nil, let event = await iterator.next() {
            if case .requestCancelled = event { cancelled = event }
        }
        guard case .requestCancelled(let cancelSID, let requestID, let method, let reason, let seq)? = cancelled else {
            return XCTFail("expected requestCancelled")
        }
        XCTAssertEqual(cancelSID, sid)
        XCTAssertEqual(requestID, "srq-fixture01")
        XCTAssertEqual(method, "approval")
        XCTAssertEqual(reason, "timeout")
        XCTAssertEqual(seq, 9)
        XCTAssertEqual(transport.openServerRequestCount, 0)

        // 3) a stale card answering afterwards is a no-op: never a denial on the wire
        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.respond(to: try XCTUnwrap(approval), choice: .deny, all: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(recorder.responses(toID: "srq-fixture01").isEmpty,
                      "a withdrawal must never be turned into a denial")
        XCTAssertFalse(recorder.methods().contains("approval.respond"))
        await transport.disconnect()
    }

    func testRequestCancelPayloadWithoutIDIsDroppedFailSoft() {
        let event = GatewayEvent(
            type: .requestCancel, rawType: "request.cancel", sessionID: sid, seq: 3,
            payload: .object(["method": .string("approval")]))
        XCTAssertNil(GatewayConversationClient.decodeEvent(event))
    }

    // MARK: 7. open_requests

    /// A `session.resume` response whose `open_requests` is the given JSON
    /// array text (pre-serialized so the fixture closure stays Sendable).
    private static func resumeFrame(id: String, openRequestsJSON: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"session_id":"abc12345","message_count":0,"messages":[],"info":{"model":"fixture-model"},"open_requests":\#(openRequestsJSON)}}"#
    }

    private func sudoEntryJSON(id: String) -> String {
        Self.json(["id": id, "method": "sudo", "params": ["session_id": sid, "command": "true"]])
    }

    func testOpenRequestsOnResumeAreRedeliveredAndAnswerable() async throws {
        let recorder = FrameRecorder()
        let entry = Self.json([
            "id": "srq-reopen01", "method": "clarify",
            "params": ["session_id": sid, "question": "Still there?", "choices": ["yes", "no"]],
        ])
        let server = try await startServer(recorder: recorder) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "session.resume" else { return [] }
            return [Self.resumeFrame(id: id, openRequestsJSON: "[\(entry)]")]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        let stream = transport.subscribeToServerRequests()

        let conversation = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let session = try await conversation.resumeSession(sessionID: sid, lastEventID: nil, profile: nil)
        XCTAssertEqual(session.sessionID, sid)

        let request = try await expectNext(stream)
        XCTAssertEqual(request.id, "srq-reopen01")
        XCTAssertTrue(request.replayed)
        guard case .clarify(let prompt) = request.kind else { return XCTFail("expected clarify kind") }
        XCTAssertEqual(prompt.questions.first?.question, "Still there?")

        // Answering the re-delivered request responds to the ORIGINAL id.
        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        try await client.answerClarify(requestID: request.id, answer: "yes")
        try await waitUntil("re-delivered answer") { !recorder.responses(toID: "srq-reopen01").isEmpty }
        await transport.disconnect()
    }

    func testOpenRequestsOnEventsSinceAreRedelivered() async throws {
        let recorder = FrameRecorder()
        let entry = Self.json([
            "id": "srq-since001", "method": "secret",
            "params": ["session_id": sid, "env_var": "FIXTURE_TOKEN", "prompt": "Token?"],
        ])
        let server = try await startServer(recorder: recorder) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "session.events.since" else { return [] }
            return [#"{"jsonrpc":"2.0","id":"\#(id)","result":{"events":[],"latest_seq":5,"truncated":false,"count":0,"epoch":"epoch-1","open_requests":[\#(entry)]}}"#]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        let stream = transport.subscribeToServerRequests()

        let conversation = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await conversation.resumeEvents(since: 3, sessionID: sid)

        let request = try await expectNext(stream)
        XCTAssertEqual(request.id, "srq-since001")
        XCTAssertTrue(request.replayed)
        guard case .secret(let prompt) = request.kind else { return XCTFail("expected secret kind") }
        XCTAssertEqual(prompt.envVar, "FIXTURE_TOKEN")
        await transport.disconnect()
    }

    func testRequestDeliveredLiveAndViaOpenRequestsSurfacesOnce() async throws {
        let recorder = FrameRecorder()
        let entry = sudoEntryJSON(id: "srq-dup00001")
        let server = try await startServer(
            onOpen: [Self.ready(), Self.requestFrame(
                id: "srq-dup00001", method: "sudo", params: ["session_id": sid, "command": "true"])],
            recorder: recorder
        ) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "session.resume" else { return [] }
            return [Self.resumeFrame(id: id, openRequestsJSON: "[\(entry)]")]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let first = try await expectNext(stream)
        XCTAssertEqual(first.id, "srq-dup00001")

        let conversation = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await conversation.resumeSession(sessionID: sid, lastEventID: nil, profile: nil)

        await assertNoNext(stream, timeout: .milliseconds(250), "the same id must not surface twice")
        XCTAssertEqual(transport.openServerRequestCount, 1)
        await transport.disconnect()
    }

    func testPendingRequestReappearsAfterReconnectViaOpenRequests() async throws {
        let recorder = FrameRecorder()
        let entry = sudoEntryJSON(id: "srq-recon001")
        let server = try await startServer(
            onOpen: [Self.ready()],
            recorder: recorder
        ) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "session.resume" else { return [] }
            return [Self.resumeFrame(id: id, openRequestsJSON: "[\(entry)]")]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        let conversation = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await conversation.resumeSession(sessionID: sid, lastEventID: nil, profile: nil)
        XCTAssertEqual(transport.openServerRequestCount, 1)

        // The socket drops: the connection's copy is discarded (the gateway
        // still holds the request).
        server.abortConnection()
        try await waitUntil("disconnect") { transport.state != .connected }
        XCTAssertEqual(transport.openServerRequestCount, 0)

        // Reconnect + resume: the gateway re-delivers it under the same id.
        try await transport.connect()
        let stream = transport.subscribeToServerRequests()
        _ = try await conversation.resumeSession(sessionID: sid, lastEventID: nil, profile: nil)
        let request = try await expectNext(stream)
        XCTAssertEqual(request.id, "srq-recon001")
        XCTAssertTrue(request.replayed)
        await transport.disconnect()
    }

    func testStaleOpenRequestsSnapshotCannotResurrectAnAnsweredRequest() async throws {
        let recorder = FrameRecorder()
        let entry = sudoEntryJSON(id: "srq-stale001")
        let server = try await startServer(
            onOpen: [Self.ready(), Self.requestFrame(
                id: "srq-stale001", method: "sudo", params: ["session_id": sid, "command": "true"])],
            recorder: recorder
        ) { frame in
            guard let (id, method, _) = Self.idAndMethod(frame), method == "session.resume" else { return [] }
            return [Self.resumeFrame(id: id, openRequestsJSON: "[\(entry)]")]
        }
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let request = try await expectNext(stream)

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        try await client.answerValue(requestID: request.id, value: "")
        let conversation = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await conversation.resumeSession(sessionID: sid, lastEventID: nil, profile: nil)

        XCTAssertEqual(transport.openServerRequestCount, 0)
        await assertNoNext(stream, timeout: .milliseconds(250), "an answered request must not reappear")
        await transport.disconnect()
    }

    // MARK: 8. timing / bounds

    func testRequestArrivingBeforeAnySubscriberIsReplayedToALateSubscriber() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-early001", method: "sudo",
                                       params: ["session_id": sid, "command": "true"])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        try await waitUntil("request parked") { transport.openServerRequestCount == 1 }
        XCTAssertTrue(recorder.responses(toID: "srq-early001").isEmpty,
                      "a parked request is not answered or withdrawn while nobody is subscribed")

        let request = try await expectNext(transport.subscribeToServerRequests())
        XCTAssertEqual(request.id, "srq-early001")
        XCTAssertTrue(request.replayed)
        await transport.disconnect()
    }

    func testOpenRequestRegistryIsBounded() async throws {
        let recorder = FrameRecorder()
        let frames = (0..<(ServerRequestBox.maxOpen + 3)).map { index in
            Self.requestFrame(
                id: String(format: "srq-flood%04d", index), method: "sudo",
                params: ["session_id": sid, "command": "true"])
        }
        let server = try await startServer(onOpen: [Self.ready()] + frames, recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        try await waitUntil("overflow refusals") {
            recorder.frames.filter { ($0["error"] as? [String: Any])?["code"] as? Int == -32603 }.count == 3
        }
        XCTAssertEqual(transport.openServerRequestCount, ServerRequestBox.maxOpen)
        await transport.disconnect()
    }

    // MARK: 9. answering while disconnected fails closed

    func testAnsweringWhileDisconnectedThrowsAndLeavesTheRequestOpen() async throws {
        let recorder = FrameRecorder()
        let server = try await startServer(
            onOpen: [Self.ready(),
                     Self.requestFrame(id: "srq-offline1", method: "sudo",
                                       params: ["session_id": sid, "command": "true"])],
            recorder: recorder)
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let stream = transport.subscribeToServerRequests()
        try await transport.connect()
        let request = try await expectNext(stream)
        await transport.disconnect()

        let client = GatewayServerPromptClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            try await client.answerValue(requestID: request.id, value: "")
            XCTFail("an answer that cannot be sent must not look like success")
        } catch let error as ConversationError {
            guard case .rpcFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
