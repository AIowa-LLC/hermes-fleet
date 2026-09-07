import XCTest
import FleetCore
@testable import FleetNetworking

/// R9-T5/T6: `GatewayManagementClient` — cron.manage (list/add/pause/resume/
/// remove/run) and skills (skills.manage list + profiles.describe +
/// profiles.configure disabled_skills) over the conversation transport,
/// against in-process fixture servers. Wire shapes verified against
/// hermes-agent 0.21.0 installed source:
/// - `cron.manage` handler (tui_gateway/methods_tools.py:1753-1827):
///   actions list/add/remove/pause/resume; job id rides the `name` param;
///   `list` forwards `include_disabled`; `run` is NOT forwarded → err 4016.
/// - list rows via `_format_job` (tools/cronjob_tools.py:753-791):
///   `{job_id, name, schedule, next_run_at, last_run_at, last_status,
///   enabled, state, prompt_preview}`; envelope `{success, count, jobs}`.
/// - `skills.manage list` (methods_tools.py:1916-1919 → banner.py:102):
///   `{skills: {category: [names...]}}`.
/// - `profiles.describe` (methods_profiles.py:596): `skills: [{name,
///   enabled}]`.
/// - `profiles.configure` (methods_profiles.py:767,935-969):
///   `{name, disabled_skills: [replace list]}` → `{ok, applied}`.
final class GatewayManagementClientTests: XCTestCase {

    // MARK: helpers

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

    /// The captured `_format_job` list shape (cronjob_tools.py:753-791).
    private static func cronListResult() -> [String: Any] {
        [
            "success": true,
            "count": 2,
            "jobs": [
                [
                    "job_id": "job-7742",
                    "name": "Morning briefing",
                    "schedule": "every day at 07:00",
                    "next_run_at": "2026-09-05T07:00:00",
                    "last_run_at": "2026-09-04T07:00:03",
                    "last_status": "ok",
                    "enabled": true,
                    "state": "enabled",
                    "prompt_preview": "Summarize fleet activity since yesterday...",
                    "deliver": "telegram",
                    "repeat": "forever",
                ],
                [
                    "job_id": "job-7743",
                    "name": "Weekly digest",
                    "schedule": "every monday at 09:00",
                    "next_run_at": nil,
                    "last_run_at": nil,
                    "last_status": nil,
                    "enabled": false,
                    "state": "paused",
                    "prompt_preview": nil,
                    "deliver": "local",
                    "repeat": "forever",
                ],
            ],
            "scoped": "default",
        ]
    }

    private static func jobRow(jobID: String, enabled: Bool) -> [String: Any] {
        [
            "success": true,
            "job": [
                "job_id": jobID,
                "name": "Morning briefing",
                "schedule": "every day at 07:00",
                "next_run_at": "2026-09-05T07:00:00",
                "last_run_at": nil,
                "last_status": nil,
                "enabled": enabled,
                "state": enabled ? "enabled" : "paused",
                "prompt_preview": "Summarize fleet activity since yesterday...",
            ],
        ]
    }

    // MARK: 1. cron.manage list

    func testCronListDecodesFormatJobRowsIncludingPaused() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: Self.cronListResult())]
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
        let jobs = try await client.listCronJobs(profile: "default")

        XCTAssertEqual(jobs.count, 2, "include_disabled list returns paused rows too")
        let morning = jobs.first { $0.jobID == "job-7742" }
        XCTAssertEqual(morning?.name, "Morning briefing")
        XCTAssertEqual(morning?.schedule, "every day at 07:00")
        XCTAssertEqual(morning?.nextRunAt, "2026-09-05T07:00:00")
        XCTAssertEqual(morning?.lastRunAt, "2026-09-04T07:00:03")
        XCTAssertEqual(morning?.lastStatus, "ok")
        XCTAssertEqual(morning?.isEnabled, true)
        XCTAssertEqual(morning?.promptPreview ?? "", "Summarize fleet activity since yesterday...")
        let paused = jobs.first { $0.jobID == "job-7743" }
        XCTAssertEqual(paused?.isEnabled, false, "paused job must surface with enabled=false")
        XCTAssertNil(paused?.nextRunAt)

        // The wire ask: action=list, include_disabled=true, profile scope.
        let (method, params) = await captured.last
        XCTAssertEqual(method, "cron.manage")
        XCTAssertEqual(params["action"] as? String, "list")
        XCTAssertEqual(params["include_disabled"] as? Bool, true,
                       "paused jobs are excluded by default — the flag must be forwarded")
        XCTAssertEqual(params["profile"] as? String, "default")
    }

    func testCronListWithoutProfileOmitsScope() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "success": true, "count": 0, "jobs": [] as [[String: Any]],
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
        let jobs = try await client.listCronJobs(profile: nil)
        XCTAssertTrue(jobs.isEmpty)

        let (_, params) = await captured.last
        XCTAssertNil(params["profile"], "nil profile must omit the scope entirely (launch profile)")
    }

    // MARK: 2. cron toggle (pause/resume)

    func testToggleSendsPauseWithJobIDInNameParam() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    let action = params["action"] as? String ?? ""
                    if action == "list" {
                        return [Self.responseFrame(id: id, result: Self.cronListResult())]
                    }
                    return [Self.responseFrame(id: id, result: Self.jobRow(
                        jobID: params["name"] as? String ?? "job-7742",
                        enabled: action != "pause"))]
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
        let updated = try await client.setCronJob("job-7742", enabled: false, profile: "default")

        XCTAssertEqual(updated.jobID, "job-7742")
        XCTAssertEqual(updated.isEnabled, false)
        let (method, params) = await captured.last
        XCTAssertEqual(method, "cron.manage")
        XCTAssertEqual(params["action"] as? String, "pause")
        XCTAssertEqual(params["name"] as? String, "job-7742",
                       "the handler reads the JOB ID from the `name` param")
        XCTAssertEqual(params["profile"] as? String, "default")
    }

    func testToggleResumeSendsResumeAction() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    let action = params["action"] as? String ?? ""
                    return [Self.responseFrame(id: id, result: Self.jobRow(
                        jobID: "job-7743", enabled: action == "resume"))]
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
        let updated = try await client.setCronJob("job-7743", enabled: true, profile: nil)
        XCTAssertEqual(updated.isEnabled, true)
        let (_, params) = await captured.last
        XCTAssertEqual(params["action"] as? String, "resume")
        XCTAssertNil(params["profile"])
    }

    // MARK: 3. fire-now (run) — wire-compat gate

    func testFireNowSendsRunActionAndMaps4016ToUnsupportedAction() async throws {
        // Ground truth: cronjob_tools.py:1765 ACCEPTS run/run_now/trigger,
        // but tui_gateway/methods_tools.py:1753-1827 does not forward it —
        // unknown cron action → err 4016. The client sends action:"run"
        // anyway (correct for gateways that add it) and a 4016 must map to
        // the typed unsupportedAction so the UI can surface an honest
        // "this gateway doesn't support run-over-WS" state.
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
            try await client.fireCronJob("job-7742", profile: "default")
            XCTFail("a 4016 unknown-action must throw unsupportedAction")
        } catch let error as GatewayManagementError {
            guard case .unsupportedAction = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
        }
        let (method, params) = await captured.last
        XCTAssertEqual(method, "cron.manage")
        XCTAssertEqual(params["action"] as? String, "run")
        XCTAssertEqual(params["name"] as? String, "job-7742")
    }

    func testFireNowSuccessDecodesExecutedFlag() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    // The background-dispatch run shape (cronjob_tools.py:1797-1814).
                    return [Self.responseFrame(id: id, result: [
                        "success": true,
                        "job": Self.jobRow(jobID: "job-7742", enabled: true)["job"]!,
                        "note": "The job is running in the background.",
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
        // Must not throw.
        try await client.fireCronJob("job-7742", profile: nil)
    }

    // MARK: 4. delete (remove)

    func testDeleteSendsRemoveAction() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "success": true,
                        "message": "Cron job 'Morning briefing' removed.",
                        "removed_job": ["id": "job-7742", "name": "Morning briefing"],
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
        try await client.deleteCronJob("job-7742", profile: "default")

        let (method, params) = await captured.last
        XCTAssertEqual(method, "cron.manage")
        XCTAssertEqual(params["action"] as? String, "remove")
        XCTAssertEqual(params["name"] as? String, "job-7742")
    }

    // MARK: 5. create (add)

    func testCreateSendsAddWithDraftFields() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "success": true,
                        "job_id": "job-9001",
                        "name": "Evening recap",
                        "schedule": "every day at 21:00",
                        "job": [
                            "job_id": "job-9001",
                            "name": "Evening recap",
                            "schedule": "every day at 21:00",
                            "next_run_at": "2026-09-04T21:00:00",
                            "enabled": true,
                            "state": "enabled",
                        ],
                        "message": "Cron job 'Evening recap' created.",
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
        let created = try await client.createCronJob(
            draft: CronJobDraft(name: "Evening recap", schedule: "every day at 21:00", prompt: "Recap the day."),
            profile: "default")

        XCTAssertEqual(created.jobID, "job-9001")
        XCTAssertEqual(created.name, "Evening recap")
        XCTAssertEqual(created.isEnabled, true)
        let (method, params) = await captured.last
        XCTAssertEqual(method, "cron.manage")
        XCTAssertEqual(params["action"] as? String, "add")
        XCTAssertEqual(params["name"] as? String, "Evening recap")
        XCTAssertEqual(params["schedule"] as? String, "every day at 21:00")
        XCTAssertEqual(params["prompt"] as? String, "Recap the day.")
        XCTAssertEqual(params["profile"] as? String, "default")
    }

    // MARK: 6. skills catalog

    func testSkillsCatalogJoinsListCategoriesWithDescribeEnablement() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                switch method {
                case "skills.manage":
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "skills": [
                            "dev": ["codex", "systematic-debugging"],
                            "github": ["github-code-review"],
                        ],
                    ])]
                case "profiles.describe":
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "name": params["name"] as? String ?? "default",
                        "skills": [
                            ["name": "codex", "enabled": true],
                            ["name": "systematic-debugging", "enabled": false],
                            ["name": "github-code-review", "enabled": true],
                        ],
                    ])]
                default:
                    return []
                }
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
        let catalog = try await client.skillsCatalog(profile: "default")

        let rows = catalog.rows
        XCTAssertEqual(rows.count, 3, "every cataloged skill gets a row")
        XCTAssertEqual(rows.first?.name, "codex")
        XCTAssertEqual(rows.first?.isEnabled, true)
        let debugging = rows.first { $0.name == "systematic-debugging" }
        XCTAssertEqual(debugging?.isEnabled, false, "disabled skill surfaces disabled")

        // Both wire calls scoped to the profile.
        let requests = await captured.all
        XCTAssertTrue(requests.contains { $0.method == "skills.manage" })
        XCTAssertTrue(requests.contains { $0.method == "profiles.describe" })
        let describeParams = requests.last { $0.method == "profiles.describe" }?.params
        XCTAssertEqual(describeParams?["name"] as? String, "default")
    }

    /// Review round 1: on a live 0.21.0 gateway, `skills.manage list`
    /// EXCLUDES disabled skills (skills_tool.py:773 `if name in disabled:
    /// continue`; no include flag on the WS handler — methods_tools.py:
    /// 1916-1919) while `profiles.describe` reports them enabled:false
    /// (methods_profiles.py:625-640). The catalog must be the UNION —
    /// a describe-only skill still gets a row (disabled) with its toggle.
    func testSkillsCatalogKeepsDescribeOnlyDisabledSkills() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                switch method {
                case "skills.manage":
                    captured.record(method, params)
                    // Server-faithful: the list pass FILTERED OUT the
                    // disabled skill (codex) — only github survives.
                    return [Self.responseFrame(id: id, result: [
                        "skills": [
                            "github": ["github-code-review"],
                        ],
                    ])]
                case "profiles.describe":
                    captured.record(method, params)
                    // Unfiltered describe: codex still reported, disabled.
                    return [Self.responseFrame(id: id, result: [
                        "name": params["name"] as? String ?? "default",
                        "skills": [
                            ["name": "codex", "enabled": false],
                            ["name": "github-code-review", "enabled": true],
                        ],
                    ])]
                default:
                    return []
                }
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
        let catalog = try await client.skillsCatalog(profile: "default")

        // The describe-only skill keeps a row, disabled, with its toggle.
        let codex = catalog.rows.first { $0.name == "codex" }
        XCTAssertNotNil(codex, "describe-only skill must not vanish from the catalog")
        XCTAssertEqual(codex?.isEnabled, false)
        // And it renders under the `installed` fallback group.
        let fallback = catalog.categories.first { $0.category == SkillsCatalog.fallbackCategory }
        XCTAssertEqual(fallback?.skills, ["codex"], "describe-only skill groups under 'installed'")
        // The listed skill is untouched by the union.
        let listed = catalog.rows.first { $0.name == "github-code-review" }
        XCTAssertEqual(listed?.isEnabled, true)
        XCTAssertEqual(catalog.rows.count, 2)
        // Both wire passes ran, scoped to the profile.
        let requests = await captured.all
        XCTAssertEqual(requests.filter { $0.method == "skills.manage" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "profiles.describe" }.count, 1)
    }

    // MARK: 7. skill toggle (profiles.configure disabled_skills)
    func testSkillToggleSendsFullReplacementDisabledList() async throws {
        let captured = ManagementParamCapture()
        // State machine: describe returns the CURRENT disabled set; configure
        // records the replacement list and flips the state.
        let state = ManagementStateBox(["systematic-debugging"])
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                switch method {
                case "profiles.describe":
                    captured.record(method, params)
                    let disabled = state.read()
                    return [Self.responseFrame(id: id, result: [
                        "name": params["name"] as? String ?? "default",
                        "skills": [
                            ["name": "codex", "enabled": !disabled.contains("codex")],
                            ["name": "systematic-debugging", "enabled": !disabled.contains("systematic-debugging")],
                        ],
                    ])]
                case "profiles.configure":
                    captured.record(method, params)
                    if let list = params["disabled_skills"] as? [String] {
                        state.write(list)
                    }
                    return [Self.responseFrame(id: id, result: [
                        "ok": true, "applied": ["skills": true],
                    ])]
                default:
                    return []
                }
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

        // ENABLE a disabled skill: the replacement disabled list drops it.
        let enabled = try await client.setSkill("systematic-debugging", enabled: true, profile: "default")
        XCTAssertTrue(enabled)
        let configureParams = await captured.all.last { $0.method == "profiles.configure" }?.params
        XCTAssertEqual(
            configureParams?["disabled_skills"] as? [String], [],
            "enabling the only disabled skill yields an EMPTY replacement list")

        // DISABLE an enabled skill: the replacement list adds it.
        let disabled = try await client.setSkill("codex", enabled: false, profile: "default")
        XCTAssertFalse(disabled)
        let secondConfigure = await captured.all.last { $0.method == "profiles.configure" }?.params
        XCTAssertEqual(
            secondConfigure?["disabled_skills"] as? [String], ["codex"])
    }

    func testSkillToggleSurfacesDescribeFailure() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "profiles.describe" {
                    return [Self.errorFrame(id: id, code: 4064, message: "profile 'nope' not found")]
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
            _ = try await client.setSkill("codex", enabled: false, profile: "nope")
            XCTFail("describe 4064 must throw profileNotFound")
        } catch let error as GatewayManagementError {
            guard case .profileNotFound = error else {
                return XCTFail("expected profileNotFound, got \(error)")
            }
        }
    }

    // MARK: 8. malformed payloads fail soft

    func testCronListMalformedJobsArrayFailsSoftWithEmptyList() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "cron.manage" {
                    // jobs is not an array (unexpected shape).
                    return [Self.responseFrame(id: id, result: ["success": true, "jobs": "nope"])]
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
        let jobs = try await client.listCronJobs(profile: nil)
        XCTAssertTrue(jobs.isEmpty, "a non-array jobs value decodes as no jobs — fail soft")
    }
}

/// Records every method + params seen (thread-safe).
final class ManagementParamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [(method: String, params: [String: Any])] = []
    var all: [(method: String, params: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return _all
    }
    var last: (method: String, params: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        return _all.last ?? ("", [:])
    }
    func record(_ method: String, _ params: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        _all.append((method, params))
    }
}

/// Thread-safe mutable fixture state.
final class ManagementStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String]
    init(_ value: [String]) { self.value = value }
    func read() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func write(_ next: [String]) {
        lock.lock(); defer { lock.unlock() }
        value = next
    }
}
