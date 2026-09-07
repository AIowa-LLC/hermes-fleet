import XCTest
import FleetCore
@testable import FleetNetworking

/// TRUE BOTS MODE slice 3 (D13) — bot-routines wire contract on
/// `cron.manage` over the real transport against in-process fixture
/// servers. Wire ground truth (hermes-agent 0.21.0):
/// - handler tui_gateway/methods_tools.py:1033-1057: actions
///   list/add/remove/pause/resume; `add` accepts optional
///   repeat/continuity/deliver ('bot-chat[:name]'); `run` NOT forwarded →
///   err 4016 `unknown cron action`.
/// - `_format_job` rows (tools/cronjob_job_args.py:346-391) include
///   deliver / repeat / last_fire_error / last_delivery_error /
///   paused_reason — the failure association the routines surface shows.
/// - `_scoped_rpc` default fail 5024; profile missing → 4064.
final class BotRoutinesNetworkingTests: XCTestCase {

    // MARK: helpers (same fixture-server pattern as
    // GatewayManagementClientTests)

    private func makeTransport(
        serverPort: UInt16,
        requestTimeout: Duration = .seconds(2)
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: requestTimeout
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func frame(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private static func readyFrame() -> String {
        frame([
            "jsonrpc": "2.0", "method": "event",
            "params": [
                "type": "gateway.ready",
                "payload": ["change_events": true, "heartbeat": false, "replay_epoch": "epoch-1"],
            ] as [String: Any],
        ])
    }

    private static func extractRequest(_ frameText: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = frameText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method, obj["params"] as? [String: Any] ?? [:])
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        frame(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        frame(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// A `_format_job` row carrying the routines-relevant fields
    /// (cronjob_job_args.py:346-391 verbatim shape).
    private static func routineRow() -> [String: Any] {
        [
            "job_id": "job-r1",
            "name": "[bot:researcher] Morning briefing",
            "schedule": "every day at 07:00",
            "next_run_at": "2026-09-08T07:00:00",
            "last_run_at": "2026-09-07T07:00:02",
            "last_status": "fire_failed",
            "last_fire_error": "agent build failed: no provider credentials",
            "last_delivery_error": nil as Any?,
            "paused_reason": nil as Any?,
            "enabled": true,
            "state": "enabled",
            "prompt_preview": "Summarize overnight fleet activity.",
            "deliver": "bot-chat:researcher",
            "repeat": "forever",
        ]
    }

    // MARK: 1. list — routines fields decode through the namespace

    func testListDecodesRoutineRowsWithFailureAndDeliverFields() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    return [Self.responseFrame(id: id, result: [
                        "success": true,
                        "count": 1,
                        "jobs": [Self.routineRow()],
                        "scoped": "researcher",
                    ])]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let jobs = try await client.listCronJobs(profile: "researcher")

        XCTAssertEqual(jobs.count, 1)
        guard let routine = BotRoutine(job: jobs[0], owner: "researcher") else {
            return XCTFail("namespaced row must parse as a routine of researcher")
        }
        XCTAssertEqual(routine.routineName, "Morning briefing")
        XCTAssertEqual(routine.lastStatus, "fire_failed")
        XCTAssertEqual(routine.failureDetail, "agent build failed: no provider credentials",
                       "last_fire_error is the failure association the surface displays")
        XCTAssertEqual(routine.deliver, "bot-chat:researcher")
        XCTAssertEqual(routine.repeatDisplay, "forever")
    }

    // MARK: 2. create — namespace + deliver + repeat ride the add params

    func testCreateRoutineSendsDeliverAndRepeatParams() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "success": true,
                        "job_id": "job-r2",
                        "job": [
                            "job_id": "job-r2",
                            "name": params["name"] as? String ?? "",
                            "schedule": params["schedule"] as? String ?? "",
                            "next_run_at": "2026-09-08T21:00:00",
                            "enabled": true,
                            "state": "enabled",
                            "deliver": params["deliver"] ?? "local",
                        ],
                    ])]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let draft = CronJobDraft(
            name: BotRoutineNamespace.jobName(owner: "researcher", routine: "Evening recap"),
            schedule: "every day at 21:00",
            prompt: "Recap the day's fleet activity.",
            deliver: "bot-chat:researcher",
            repeatCount: 3)
        let created = try await client.createCronJob(draft: draft, profile: "researcher")

        XCTAssertEqual(created.jobID, "job-r2")
        XCTAssertEqual(created.name, "[bot:researcher] Evening recap")
        XCTAssertEqual(created.deliver, "bot-chat:researcher")
        XCTAssertNotNil(BotRoutine(job: created, owner: "researcher"))

        let (_, params) = await captured.last
        XCTAssertEqual(params["action"] as? String, "add")
        XCTAssertEqual(params["name"] as? String, "[bot:researcher] Evening recap",
                       "the [bot:<owner>] namespace rides the job name verbatim")
        XCTAssertEqual(params["deliver"] as? String, "bot-chat:researcher")
        XCTAssertEqual(params["repeat"] as? Int, 3)
        XCTAssertEqual(params["profile"] as? String, "researcher",
                       "the routine lands in the OWNING bot's per-profile cron store")
    }

    func testCreateRoutineWithoutDeliverOmitsParam() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "success": true,
                        "job": ["job_id": "job-r3", "name": params["name"] as? String ?? "",
                                "schedule": "every day at 08:00", "enabled": true, "state": "enabled"],
                    ])]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.createCronJob(
            draft: CronJobDraft(
                name: "[bot:researcher] Early notes",
                schedule: "every day at 08:00",
                prompt: "Draft early notes."),
            profile: "researcher")

        let (_, params) = await captured.last
        XCTAssertNil(params["deliver"], "nil deliver must omit the param (gateway default)")
        XCTAssertNil(params["repeat"])
    }

    // MARK: 3. run-now — honest unsupported (4016 → typed gate)

    func testFireRoutineMaps4016ToUnsupportedActionNotFacade() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.errorFrame(id: id, code: 4016, message: "unknown cron action: run")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            try await client.fireCronJob("job-r1", profile: "researcher")
            XCTFail("4016 must throw unsupportedAction — never a fabricated success")
        } catch let error as GatewayManagementError {
            guard case .unsupportedAction = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
        }
        // The attempt was made with the correct wire spelling — gateways
        // that DO forward `run` keep working.
        let (_, params) = await captured.last
        XCTAssertEqual(params["action"] as? String, "run")
        XCTAssertEqual(params["name"] as? String, "job-r1")
        XCTAssertEqual(params["profile"] as? String, "researcher")
    }

    // MARK: 4. scoped failure — 5024 handler fail / 4064 profile missing

    func testScopedFailureDecodesTyped() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    // Ground truth: _profile_scoped_rpc maps a missing
                    // profile dir to 4064; handler body exceptions become
                    // the fail_code (5023/5024 family per decorator).
                    return [Self.errorFrame(id: id, code: 4064, message: "profile 'ghost' not found")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.listCronJobs(profile: "ghost")
            XCTFail("4064 must throw profileNotFound")
        } catch let error as GatewayManagementError {
            guard case .profileNotFound = error else {
                return XCTFail("expected profileNotFound, got \(error)")
            }
        }
    }

    func testHandlerFailure5024DecodesRpcFailed() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    return [Self.errorFrame(id: id, code: 5024, message: "cronjob failed: schedule parse error")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.listCronJobs(profile: "researcher")
            XCTFail("5024 must throw rpcFailed")
        } catch let error as GatewayManagementError {
            guard case .rpcFailed = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
        }
    }

    // MARK: 5. old gateway — method unknown → honest unavailable

    func testOldGatewayWithoutCronManageFailsTyped() async throws {
        // Ground truth: a gateway that predates cron.manage answers
        // method-not-found (-32601). The client surfaces it typed; the UI
        // gates the routines surface with an explanation — never a
        // semantic fallback.
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found: cron.manage")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayManagementClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.listCronJobs(profile: "researcher")
            XCTFail("method-not-found must throw — no fallback")
        } catch let error as GatewayManagementError {
            guard case .rpcFailed = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
