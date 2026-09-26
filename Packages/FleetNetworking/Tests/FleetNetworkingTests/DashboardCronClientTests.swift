import XCTest
import FleetCore
@testable import FleetNetworking

/// Card B — `DashboardCronClient` contract tests. Fixtures are the LIVE
/// payload shapes captured from the dev gateway's dashboard REST surface
/// (`/api/cron/jobs*`); the URLProtocol mock asserts method, path, query and
/// request body per call, so a contract drift fails here instead of on a
/// device.
final class DashboardCronClientTests: XCTestCase {

    // MARK: - Pure URL builders

    func testJobsURLIncludesProfileWhenPresent() throws {
        let base = try XCTUnwrap(URL(string: "http://gateway.example.invalid:18923"))
        let url = try XCTUnwrap(DashboardCronClient.jobsURL(base: base, profile: "default"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/api/cron/jobs")
        XCTAssertTrue((comps.queryItems ?? []).contains(URLQueryItem(name: "profile", value: "default")))
    }

    func testJobsURLOmitsProfileWhenAllOrNil() throws {
        let base = try XCTUnwrap(URL(string: "http://gateway.example.invalid:18923"))
        for profile in [nil, ""] as [String?] {
            let url = try XCTUnwrap(DashboardCronClient.jobsURL(base: base, profile: profile))
            let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(comps.path, "/api/cron/jobs")
            XCTAssertNil(comps.queryItems, "nil/blank profile must omit the param")
        }
    }

    func testJobAndActionURLs() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid"))
        let job = try XCTUnwrap(DashboardCronClient.jobURL(base: base, id: "78799ffb8210", profile: "default"))
        XCTAssertEqual(job.path, "/api/cron/jobs/78799ffb8210")
        let trigger = try XCTUnwrap(DashboardCronClient.jobActionURL(base: base, id: "78799ffb8210", action: "trigger", profile: "default"))
        XCTAssertEqual(trigger.path, "/api/cron/jobs/78799ffb8210/trigger")
        let runs = try XCTUnwrap(DashboardCronClient.runsURL(base: base, id: "abc", profile: nil, limit: 20))
        XCTAssertEqual(runs.path, "/api/cron/jobs/abc/runs")
        let comps = try XCTUnwrap(URLComponents(url: runs, resolvingAgainstBaseURL: false))
        XCTAssertTrue((comps.queryItems ?? []).contains(URLQueryItem(name: "limit", value: "20")))
    }

    func testRunsURLEscapesHumanJobRefs() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid"))
        let url = try XCTUnwrap(DashboardCronClient.runsURL(base: base, id: "a b/c", profile: nil, limit: 5))
        // The job ref rides a single, percent-encoded path segment.
        XCTAssertEqual(url.path, "/api/cron/jobs/a%20b%2Fc/runs")
    }

    func testRunsURLClampsLimitToServerWindow() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid"))
        func limit(_ raw: Int) throws -> String {
            let url = try XCTUnwrap(DashboardCronClient.runsURL(base: base, id: "x", profile: nil, limit: raw))
            let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            return (comps.queryItems ?? []).first { $0.name == "limit" }?.value ?? ""
        }
        XCTAssertEqual(try limit(0), "1")
        XCTAssertEqual(try limit(500), "100")
        XCTAssertEqual(try limit(7), "7")
    }

    /// [low] The builder returns an OPTIONAL like every other URL builder in
    /// the file (a caller-supplied base URL must never be force-unwrapped), and
    /// it still clears any query the base carried.
    func testDeliveryTargetsURL() throws {
        let base = try XCTUnwrap(URL(string: "http://gw.example.invalid:18923"))
        let url = try XCTUnwrap(DashboardCronClient.deliveryTargetsURL(base: base))
        XCTAssertEqual(url.path, "/api/cron/delivery-targets")

        let baseWithQuery = try XCTUnwrap(URL(string: "http://gw.example.invalid:18923/?token=1"))
        let cleared = try XCTUnwrap(DashboardCronClient.deliveryTargetsURL(base: baseWithQuery))
        XCTAssertEqual(cleared.absoluteString, "http://gw.example.invalid:18923/api/cron/delivery-targets",
                       "the base's query must not ride the delivery-targets URL")
    }

    // MARK: - List + detail decode (live shapes)

    /// The captured list row (dev gateway, `/api/cron/jobs?profile=all`):
    /// a bare array whose rows carry the full record + latest_execution +
    /// per-profile annotation.
    private static let listBody = Data(#"""
    [{"id":"0d6e0654a3bf","name":"fleet-pin-agent","prompt":"say pin","skills":[],"skill":null,
      "model":"gpt-5.2","provider":null,"provider_snapshot":null,"model_snapshot":null,"base_url":null,
      "script":null,"no_agent":false,"monitor_script":null,"monitor_url":null,"monitor_state":null,
      "context_from":null,"schedule":{"kind":"cron","expr":"0 3 * * *","display":"0 3 * * *"},
      "schedule_display":"0 3 * * *","repeat":{"times":null,"completed":2},"enabled":true,"state":"scheduled",
      "paused_at":null,"paused_reason":null,"created_at":"2026-09-17T01:36:21.643921-05:00",
      "next_run_at":"2026-09-17T03:00:00-05:00","last_run_at":"2026-09-17T01:38:19.519486-05:00",
      "last_status":"blocked_config","last_error":"[blocked_config] provider credential missing",
      "last_delivery_error":null,"last_delivery_unverified":null,"failure_streak":2,"deliver":"local",
      "origin":null,"enabled_toolsets":null,"workdir":null,"fire_claim":null,"preflight_alerted":true,
      "latest_execution":{"id":"234804fadae146c29e364764358b7e29","job_id":"0d6e0654a3bf","source":"builtin",
        "process_id":"444b561f593241ed8d150408e5bdf050","pid":25858,"process_started_at":178962691242,
        "status":"failed","handoff_pending":0,"handoff_started_at":null,
        "claimed_at":"2026-09-17T01:38:19.445312-05:00","started_at":"2026-09-17T01:38:19.469868-05:00",
        "finished_at":"2026-09-17T01:38:19.519934-05:00","error":"[blocked_config] provider credential missing",
        "delivery_outcome":"suppressed","scheduled_instant":null},
      "profile":"default","profile_name":"default","hermes_home":"/tmp/fleet-dev-gateway",
      "is_default_profile":true}]
    """#.utf8)

    func testListDecodesBareArrayWithExecutionLedgerAndProfileAttribution() async throws {
        let client = Self.makeClient(handler: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")
            XCTAssertTrue((request.url?.query ?? "").contains("profile=all"))
            return (200, Self.listBody)
        })
        let jobs = try await client.listJobs(profile: "all")
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.id, "0d6e0654a3bf")
        XCTAssertEqual(job.name, "fleet-pin-agent")
        XCTAssertEqual(job.schedule.kind, "cron")
        XCTAssertEqual(job.schedule.expr, "0 3 * * *")
        XCTAssertEqual(job.scheduleDisplay, "0 3 * * *")
        XCTAssertEqual(job.displayState, "scheduled")
        XCTAssertEqual(job.deliver, "local")
        XCTAssertEqual(job.repeatCompleted, 2)
        XCTAssertEqual(job.profile, "default")
        XCTAssertTrue(job.isDefaultProfile)
        XCTAssertEqual(job.failureStreak, 2)
        let execution = try XCTUnwrap(job.latestExecution)
        XCTAssertEqual(execution.status, "failed")
        XCTAssertEqual(execution.deliveryOutcome, "suppressed")
        XCTAssertEqual(execution.pid, 25858)
        XCTAssertNotNil(execution.finishedAt)
    }

    func testJobDecodeToleratesNullsAndMissingOptionalKeys() async throws {
        // A script job created by the dashboard: no prompt, script set,
        // no_agent true — plus a body that omits several optional keys.
        let body = Data(#"""
        {"id":"0d1137f872e6","name":"fleet-b-contract-script","prompt":"","schedule":{"kind":"cron","expr":"*/30 * * * *","display":"*/30 * * * *"},
         "enabled":true,"state":"scheduled","no_agent":true,"script":"fleet_pin.sh","deliver":"local",
         "created_at":"2026-09-17T01:58:34.812127-05:00","next_run_at":"2026-09-17T02:30:00-05:00",
         "profile":"default","is_default_profile":true}
        """#.utf8)
        let client = Self.makeClient(handler: { _ in (200, body) })
        let job = try await client.job(id: "0d1137f872e6", profile: "default")
        XCTAssertTrue(job.noAgent)
        XCTAssertEqual(job.script, "fleet_pin.sh")
        XCTAssertEqual(job.scheduleDisplay, "*/30 * * * *")
        XCTAssertNil(job.latestExecution)
        XCTAssertNil(job.repeatCompleted)
    }

    // MARK: - Mutations

    func testCreateSendsFormFieldsAndDecodesRecord() async throws {
        var seenBody: [String: Any]?
        let client = Self.makeClient(handler: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")
            XCTAssertTrue((request.url?.query ?? "").contains("profile=default"))
            seenBody = request.jsonBody()
            return (200, Data(#"{"id":"78799ffb8210","name":"fleet-b-contract-agent","schedule":{"kind":"cron","expr":"0 6 * * *","display":"0 6 * * *"},"enabled":true,"state":"scheduled","deliver":"local","profile":"default"}"#.utf8))
        })
        let created = try await client.createJob(
            CronJobCreateRequest(name: "fleet-b-contract-agent", schedule: "0 6 * * *", prompt: "Report the fleet state."),
            profile: "default")
        XCTAssertEqual(created.id, "78799ffb8210")
        XCTAssertEqual(seenBody?["name"] as? String, "fleet-b-contract-agent")
        XCTAssertEqual(seenBody?["schedule"] as? String, "0 6 * * *")
        XCTAssertEqual(seenBody?["prompt"] as? String, "Report the fleet state.")
        XCTAssertEqual(seenBody?["deliver"] as? String, "local", "deliver defaults to local")
    }

    func testCreateRejectsInvalidDraftBeforeAnyRequest() async throws {
        var requested = false
        let client = Self.makeClient(handler: { _ in
            requested = true
            return (200, Data())
        })
        do {
            _ = try await client.createJob(CronJobCreateRequest(name: "x", schedule: "", prompt: "p"), profile: nil)
            XCTFail("expected validation error")
        } catch let error as CronDashboardError {
            XCTAssertEqual(error, .invalidRequest("a job needs a name, a schedule, and a prompt"))
        }
        XCTAssertFalse(requested, "invalid drafts must not reach the gateway")
    }

    func testUpdateSendsOnlyChangedKeysAndPreservesIdentity() async throws {
        var seenBody: [String: Any]?
        let client = Self.makeClient(handler: { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/78799ffb8210")
            seenBody = request.jsonBody()
            // The live PUT response: SAME id after a rename.
            return (200, Data(#"{"id":"78799ffb8210","name":"fleet-b-contract-agent-v2","schedule":{"kind":"cron","expr":"0 6 * * *","display":"0 6 * * *"},"enabled":true,"state":"scheduled","deliver":"local","profile":"default"}"#.utf8))
        })
        let updated = try await client.updateJob(
            id: "78799ffb8210",
            patch: CronJobPatch(name: "fleet-b-contract-agent-v2"),
            profile: "default")
        XCTAssertEqual(updated.id, "78799ffb8210", "PUT preserves identity — never a delete-recreate")
        XCTAssertEqual(updated.name, "fleet-b-contract-agent-v2")
        let updates = try XCTUnwrap(seenBody?["updates"] as? [String: Any])
        XCTAssertEqual(updates["name"] as? String, "fleet-b-contract-agent-v2")
        XCTAssertEqual(updates.count, 1, "unchanged fields must not ride the payload")
        XCTAssertNil(seenBody?["name"], "updates must be nested under the updates key")
    }

    func testUpdateWithEmptyPatchIsRefusedLocally() async throws {
        let client = Self.makeClient(handler: { _ in (200, Data()) })
        do {
            _ = try await client.updateJob(id: "x", patch: CronJobPatch(), profile: nil)
            XCTFail("expected refusal")
        } catch let error as CronDashboardError {
            XCTAssertEqual(error, .invalidRequest("nothing to update"))
        }
    }

    func testPauseResumeTriggerPaths() async throws {
        var paths: [String] = []
        let client = Self.makeClient(handler: { request in
            paths.append("\(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
            return (200, Data(#"{"id":"job-1","name":"n","schedule":{"kind":"cron","expr":"* * * * *","display":"* * * * *"},"enabled":true,"state":"scheduled"}"#.utf8))
        })
        _ = try await client.pauseJob(id: "job-1", profile: "default")
        _ = try await client.resumeJob(id: "job-1", profile: "default")
        _ = try await client.triggerJob(id: "job-1", profile: "default")
        XCTAssertEqual(paths, [
            "POST /api/cron/jobs/job-1/pause",
            "POST /api/cron/jobs/job-1/resume",
            "POST /api/cron/jobs/job-1/trigger",
        ])
    }

    func testTriggerConflictMapsToAlreadyRunning() async throws {
        let client = Self.makeClient(handler: { _ in
            (409, Data(#"{"detail":"Job is already running or was claimed by another scheduler"}"#.utf8))
        })
        do {
            _ = try await client.triggerJob(id: "job-1", profile: "default")
            XCTFail("expected conflict")
        } catch let error as CronDashboardError {
            XCTAssertTrue(error.isAlreadyRunning)
            XCTAssertEqual(error.errorDescription, "Job is already running or was claimed by another scheduler")
        }
    }

    func testDeleteSendsDELETEAndMaps404() async throws {
        var method: String?
        let client = Self.makeClient(handler: { request in
            method = request.httpMethod
            return (200, Data(#"{"ok":true}"#.utf8))
        })
        try await client.deleteJob(id: "job-1", profile: "default")
        XCTAssertEqual(method, "DELETE")

        let missing = Self.makeClient(handler: { _ in (404, Data(#"{"detail":"Job not found"}"#.utf8)) })
        do {
            try await missing.deleteJob(id: "nope", profile: nil)
            XCTFail("expected notFound")
        } catch let error as CronDashboardError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - Runs + delivery targets

    func testRunSessionsDecodeAgentRuns() async throws {
        let body = Data(#"""
        {"runs":[{"id":"cron_78799ffb8210_1789627000","title":"Cron: fleet-b-contract-agent","source":"cron",
          "started_at":1789627000.5,"ended_at":1789627030.25,"last_active":1789627031.0,"message_count":6,
          "preview":"Report the fleet state.","profile":"default","is_active":false,"archived":false}],"limit":20}
        """#.utf8)
        let client = Self.makeClient(handler: { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/78799ffb8210/runs")
            return (200, body)
        })
        let runs = try await client.runSessions(jobID: "78799ffb8210", profile: "default", limit: 20)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.id, "cron_78799ffb8210_1789627000")
        XCTAssertEqual(run.messageCount, 6)
        XCTAssertEqual(run.startedAt, 1_789_627_000.5)
        XCTAssertFalse(run.isActive)
        XCTAssertEqual(run.profile, "default")
    }

    func testRunSessionsEmptyForScriptJobsIsNotAnError() async throws {
        let client = Self.makeClient(handler: { _ in (200, Data(#"{"runs":[],"limit":20}"#.utf8)) })
        let runs = try await client.runSessions(jobID: "script-1", profile: "default", limit: 20)
        XCTAssertTrue(runs.isEmpty, "no_agent script jobs have no run sessions by design")
    }

    func testDeliveryTargetsDecode() async throws {
        let body = Data(#"""
        {"targets":[{"id":"local","name":"Local (save only)","home_target_set":true,"home_env_var":null},
                    {"id":"bot-chat:default","name":"Bot Chat (default)","home_target_set":true,"home_env_var":null},
                    {"id":"telegram","name":"Telegram","home_target_set":false,"home_env_var":"TELEGRAM_CHAT_ID"}]}
        """#.utf8)
        let client = Self.makeClient(handler: { request in
            XCTAssertEqual(request.url?.path, "/api/cron/delivery-targets")
            return (200, body)
        })
        let targets = try await client.deliveryTargets()
        XCTAssertEqual(targets.map(\.id), ["local", "bot-chat:default", "telegram"])
        XCTAssertFalse(try XCTUnwrap(targets.last).homeTargetSet)
        XCTAssertEqual(targets.last?.homeEnvVar, "TELEGRAM_CHAT_ID")
    }

    // MARK: - Auth + error mapping

    func testSessionTokenCredentialRidesTheRequest() async throws {
        var headers: [String: String] = [:]
        let client = Self.makeClient(
            credential: { .sessionTokenHeader("test-session-token") },
            handler: { request in
                headers = request.allHTTPHeaderFields ?? [:]
                return (200, Data("[]".utf8))
            })
        _ = try await client.listJobs(profile: "default")
        XCTAssertEqual(headers["X-Hermes-Session-Token"], "test-session-token")
    }

    func testCookieCredentialRidesTheRequest() async throws {
        var headers: [String: String] = [:]
        let client = Self.makeClient(
            credential: { .cookie(SessionCookie(name: "hermes_session", value: "cookie-value")) },
            handler: { request in
                headers = request.allHTTPHeaderFields ?? [:]
                return (200, Data("[]".utf8))
            })
        _ = try await client.listJobs(profile: nil)
        XCTAssertEqual(headers["Cookie"], "hermes_session=cookie-value")
    }

    func testUnauthorizedMapsTo401() async throws {
        let client = Self.makeClient(handler: { _ in
            (401, Data(#"{"detail":"unauthorized"}"#.utf8))
        })
        do {
            _ = try await client.listJobs(profile: nil)
            XCTFail("expected unauthorized")
        } catch let error as CronDashboardError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertEqual(error.errorDescription, "the gateway rejected the dashboard session — reconnect this gateway")
        }
    }

    func testValidationErrorSurfacesServerDetail() async throws {
        let client = Self.makeClient(handler: { _ in
            (400, Data(#"{"detail":"Invalid schedule: not a valid cron expression"}"#.utf8))
        })
        do {
            _ = try await client.createJob(
                CronJobCreateRequest(name: "n", schedule: "whenever", prompt: "p"), profile: "default")
            XCTFail("expected invalidRequest")
        } catch let error as CronDashboardError {
            XCTAssertEqual(error, .invalidRequest("Invalid schedule: not a valid cron expression"))
            XCTAssertEqual(error.errorDescription, "Invalid schedule: not a valid cron expression")
        }
    }

    func testMalformedListBodyThrows() async throws {
        let client = Self.makeClient(handler: { _ in (200, Data("not json".utf8)) })
        do {
            _ = try await client.listJobs(profile: nil)
            XCTFail("expected malformedResponse")
        } catch let error as CronDashboardError {
            guard case .malformedResponse = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: - Franchise test plumbing

    private static func makeClient(
        credential: @escaping @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential = { .none },
        handler: @escaping (URLRequest) -> (Int, Data)
    ) -> DashboardCronClient {
        CronURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CronURLProtocol.self]
        return DashboardCronClient(
            gatewayID: GatewayID(rawValue: "g1"),
            baseURL: URL(string: "http://gateway.example.invalid:18923")!,
            httpCredential: credential,
            urlSession: URLSession(configuration: config))
    }
}

/// URLProtocol mock: routes every request into the test-supplied handler and
/// re-surfaces the request (method/path/query/body) for assertions.
final class CronURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession hands the mock a stream-backed body; read it back so tests
    /// can assert the exact JSON payload.
    func jsonBody() -> [String: Any]? {
        var data: Data?
        if let httpBody {
            data = httpBody
        } else if let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}