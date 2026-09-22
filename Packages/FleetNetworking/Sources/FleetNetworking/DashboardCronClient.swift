import Foundation
import os
import FleetCore

/// Card B — the dashboard REST cron client (`/api/cron/jobs*`).
///
/// Auth mirrors the kanban REST fetches exactly: the caller injects the
/// strategy-appropriate `KanbanEventStreamClient.HTTPCredential` resolver
/// (`X-Hermes-Session-Token` header for loopback/session/bearer strategies,
/// a fresh password-login cookie for username/password deployments). The WS
/// credential path is NOT reused blindly — the dashboard gates HTTP routes on
/// its own session middleware.
///
/// Wire contract: see `CronDashboardProviding` (FleetCore) — verified against
/// hermes-agent's `hermes_cli/web_routers/cron.py` and captured live from the
/// dev gateway (`build/b-cron-evidence/live/*.json`).
public struct DashboardCronClient: CronDashboardProviding, Sendable {
    public let gatewayID: GatewayID
    /// HTTP base of the dashboard server (`http(s)://host:port`).
    let baseURL: URL
    /// Resolved per request (fresh password-login cookies are per-fetch, the
    /// same discipline as the kanban board fetches).
    let httpCredential: @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential
    let urlSession: URLSession

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "dashboard-cron")

    public init(
        gatewayID: GatewayID,
        baseURL: URL,
        httpCredential: @escaping @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential = { .none },
        urlSession: URLSession = .shared
    ) {
        self.gatewayID = gatewayID
        self.baseURL = baseURL
        self.httpCredential = httpCredential
        self.urlSession = urlSession
    }

    // MARK: - URL building (pure, testable)

    /// `…/api/cron/jobs?profile=<p>` (no `profile` param when nil).
    public static func jobsURL(base: URL, profile: String?) -> URL? {
        url(base: base, path: "/api/cron/jobs", query: profileQuery(profile))
    }

    /// `…/api/cron/jobs/{id}?profile=<p>`.
    public static func jobURL(base: URL, id: String, profile: String?) -> URL? {
        url(base: base, path: "/api/cron/jobs/\(encodedSegment(id))", query: profileQuery(profile))
    }

    /// `…/api/cron/jobs/{id}/{action}?profile=<p>` (`pause`/`resume`/`trigger`).
    public static func jobActionURL(base: URL, id: String, action: String, profile: String?) -> URL? {
        url(base: base, path: "/api/cron/jobs/\(encodedSegment(id))/\(encodedSegment(action))", query: profileQuery(profile))
    }

    /// `…/api/cron/jobs/{id}/runs?profile=<p>&limit=<n>` (limit clamped to
    /// the server's own 1…100 window).
    public static func runsURL(base: URL, id: String, profile: String?, limit: Int) -> URL? {
        var query = profileQuery(profile)
        query.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))))
        return url(base: base, path: "/api/cron/jobs/\(encodedSegment(id))/runs", query: query)
    }

    /// `…/api/cron/delivery-targets`. `nil` for a base URL the components
    /// parser cannot use — the caller maps that to `.malformedResponse`, the
    /// same discipline as every other builder in this file (never a trap on
    /// caller-supplied input).
    public static func deliveryTargetsURL(base: URL) -> URL? {
        url(base: base, path: "/api/cron/delivery-targets", query: [])
    }

    private static func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    /// Job ids are usually hex, but the dashboard accepts human names as
    /// refs — percent-encode the path segment as a STRICT single segment
    /// (unreserved characters only), so a ref containing `/` or `?` cannot
    /// forge extra path segments.
    static func encodedSegment(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func url(base: URL, path: String, query: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url
    }

    // MARK: - CronDashboardProviding

    public func listJobs(profile: String?) async throws -> [CronJobRecord] {
        guard let url = Self.jobsURL(base: baseURL, profile: profile) else {
            throw CronDashboardError.malformedResponse("bad jobs URL")
        }
        let data = try await perform(url: url, method: "GET")
        // The list endpoint answers a bare JSON ARRAY of job records.
        do {
            let payloads = try JSONDecoder().decode([JobPayload].self, from: data)
            return payloads.map { $0.toRecord() }
        } catch {
            throw CronDashboardError.malformedResponse("jobs list decode failed")
        }
    }

    public func job(id: String, profile: String?) async throws -> CronJobRecord {
        guard let url = Self.jobURL(base: baseURL, id: id, profile: profile) else {
            throw CronDashboardError.malformedResponse("bad job URL")
        }
        let data = try await perform(url: url, method: "GET")
        return try Self.decodeJob(data)
    }

    @discardableResult
    public func createJob(_ request: CronJobCreateRequest, profile: String?) async throws -> CronJobRecord {
        guard request.isValid else {
            throw CronDashboardError.invalidRequest("a job needs a name, a schedule, and a prompt")
        }
        guard let url = Self.jobsURL(base: baseURL, profile: profile) else {
            throw CronDashboardError.malformedResponse("bad jobs URL")
        }
        var body: [String: Any] = [
            "name": request.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "schedule": request.schedule.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompt": request.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "deliver": request.deliver.isEmpty ? "local" : request.deliver,
        ]
        if let script = request.script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            body["script"] = script
            body["no_agent"] = true
        }
        let data = try await perform(url: url, method: "POST", jsonBody: body)
        return try Self.decodeJob(data)
    }

    @discardableResult
    public func updateJob(id: String, patch: CronJobPatch, profile: String?) async throws -> CronJobRecord {
        guard !patch.isEmpty else {
            throw CronDashboardError.invalidRequest("nothing to update")
        }
        guard let url = Self.jobURL(base: baseURL, id: id, profile: profile) else {
            throw CronDashboardError.malformedResponse("bad job URL")
        }
        // PUT body is `{"updates": {…}}` (CronJobUpdate). Only changed keys
        // ride the payload — absent keys keep their stored values.
        let data = try await perform(
            url: url, method: "PUT", jsonBody: ["updates": patch.wireUpdates])
        return try Self.decodeJob(data)
    }

    @discardableResult
    public func pauseJob(id: String, profile: String?) async throws -> CronJobRecord {
        try await jobAction(id: id, action: "pause", profile: profile)
    }

    @discardableResult
    public func resumeJob(id: String, profile: String?) async throws -> CronJobRecord {
        try await jobAction(id: id, action: "resume", profile: profile)
    }

    @discardableResult
    public func triggerJob(id: String, profile: String?) async throws -> CronJobRecord {
        try await jobAction(id: id, action: "trigger", profile: profile)
    }

    private func jobAction(id: String, action: String, profile: String?) async throws -> CronJobRecord {
        guard let url = Self.jobActionURL(base: baseURL, id: id, action: action, profile: profile) else {
            throw CronDashboardError.malformedResponse("bad job action URL")
        }
        let data = try await perform(url: url, method: "POST")
        return try Self.decodeJob(data)
    }

    public func deleteJob(id: String, profile: String?) async throws {
        guard let url = Self.jobURL(base: baseURL, id: id, profile: profile) else {
            throw CronDashboardError.malformedResponse("bad job URL")
        }
        _ = try await perform(url: url, method: "DELETE")
    }

    public func runSessions(jobID: String, profile: String?, limit: Int = 20) async throws -> [CronRunSession] {
        guard let url = Self.runsURL(base: baseURL, id: jobID, profile: profile, limit: limit) else {
            throw CronDashboardError.malformedResponse("bad runs URL")
        }
        let data = try await perform(url: url, method: "GET")
        struct Envelope: Decodable {
            let runs: [RunPayload]
        }
        struct RunPayload: Decodable {
            let id: String
            let title: String?
            let source: String?
            let started_at: Double?
            let ended_at: Double?
            let last_active: Double?
            let message_count: Int?
            let preview: String?
            let profile: String?
            let is_active: Bool?
            let archived: Bool?
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.runs.map { run in
                CronRunSession(
                    id: run.id,
                    title: run.title ?? run.id,
                    source: run.source,
                    startedAt: run.started_at,
                    endedAt: run.ended_at,
                    lastActive: run.last_active,
                    messageCount: run.message_count,
                    preview: run.preview,
                    profile: run.profile,
                    isActive: run.is_active ?? false,
                    archived: run.archived ?? false)
            }
        } catch {
            throw CronDashboardError.malformedResponse("runs decode failed")
        }
    }

    public func deliveryTargets() async throws -> [CronDeliveryTarget] {
        guard let url = Self.deliveryTargetsURL(base: baseURL) else {
            throw CronDashboardError.malformedResponse("bad delivery-targets URL")
        }
        let data = try await perform(url: url, method: "GET")
        struct Envelope: Decodable {
            let targets: [TargetPayload]
        }
        struct TargetPayload: Decodable {
            let id: String
            let name: String?
            let home_target_set: Bool?
            let home_env_var: String?
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.targets.map {
                CronDeliveryTarget(
                    id: $0.id,
                    name: $0.name ?? $0.id,
                    homeTargetSet: $0.home_target_set ?? true,
                    homeEnvVar: $0.home_env_var)
            }
        } catch {
            throw CronDashboardError.malformedResponse("delivery targets decode failed")
        }
    }

    // MARK: - Job record decode

    /// The full 42-key REST row (`_normalize_job_record` + `latest_execution`
    /// + `_annotate_cron_job`); unknown keys are ignored.
    struct JobPayload: Decodable {
        let id: String
        let name: String?
        let prompt: String?
        let skills: [String]?
        let model: String?
        let provider: String?
        let script: String?
        let no_agent: Bool?
        let schedule: SchedulePayload?
        let schedule_display: String?
        let repeatInfo: RepeatPayload?
        let enabled: Bool?
        let state: String?
        let paused_at: String?
        let paused_reason: String?
        let created_at: String?
        let updated_at: String?
        let next_run_at: String?
        let last_run_at: String?
        let last_status: String?
        let last_error: String?
        let last_delivery_error: String?
        let last_delivery_unverified: String?
        let failure_streak: Int?
        let deliver: String?
        let failure_deliver: String?
        let profile: String?
        let profile_name: String?
        let is_default_profile: Bool?
        let latest_execution: ExecutionPayload?

        /// `repeat` is a Swift keyword — the wire key needs an alias.
        enum CodingKeys: String, CodingKey {
            case id, name, prompt, skills, model, provider, script, no_agent
            case schedule, schedule_display, enabled, state
            case paused_at, paused_reason, created_at, updated_at
            case next_run_at, last_run_at, last_status, last_error
            case last_delivery_error, last_delivery_unverified, failure_streak
            case deliver, failure_deliver, profile, profile_name, is_default_profile
            case latest_execution
            case repeatInfo = "repeat"
        }

        struct SchedulePayload: Decodable {
            let kind: String?
            let expr: String?
            let display: String?
        }

        struct RepeatPayload: Decodable {
            let times: Int?
            let completed: Int?
        }

        struct ExecutionPayload: Decodable {
            let id: String?
            let status: String?
            let source: String?
            let pid: Int?
            let claimed_at: String?
            let started_at: String?
            let finished_at: String?
            let error: String?
            let delivery_outcome: String?
            let scheduled_instant: String?
        }

        func toRecord() -> CronJobRecord {
            CronJobRecord(
                id: id,
                name: name ?? id,
                prompt: prompt ?? "",
                schedule: CronSchedule(
                    kind: schedule?.kind ?? "",
                    expr: schedule?.expr ?? "",
                    display: schedule?.display ?? schedule_display ?? ""),
                scheduleDisplay: schedule_display,
                enabled: enabled ?? true,
                state: state ?? "",
                noAgent: no_agent ?? false,
                script: script,
                skills: skills ?? [],
                model: model,
                provider: provider,
                deliver: deliver ?? "local",
                failureDeliver: failure_deliver,
                nextRunAt: next_run_at,
                lastRunAt: last_run_at,
                lastStatus: last_status,
                lastError: last_error,
                lastDeliveryError: last_delivery_error,
                lastDeliveryUnverified: last_delivery_unverified,
                failureStreak: failure_streak,
                pausedAt: paused_at,
                pausedReason: paused_reason,
                createdAt: created_at,
                updatedAt: updated_at,
                repeatTimes: repeatInfo?.times,
                repeatCompleted: repeatInfo?.completed,
                profile: profile,
                profileName: profile_name,
                isDefaultProfile: is_default_profile ?? false,
                latestExecution: latest_execution.map { execution in
                    CronExecution(
                        id: execution.id ?? "unknown",
                        status: execution.status ?? "unknown",
                        source: execution.source,
                        pid: execution.pid,
                        claimedAt: execution.claimed_at,
                        startedAt: execution.started_at,
                        finishedAt: execution.finished_at,
                        error: execution.error,
                        deliveryOutcome: execution.delivery_outcome,
                        scheduledInstant: execution.scheduled_instant)
                })
        }
    }

    static func decodeJob(_ data: Data) throws -> CronJobRecord {
        do {
            return try JSONDecoder().decode(JobPayload.self, from: data).toRecord()
        } catch {
            throw CronDashboardError.malformedResponse("job decode failed")
        }
    }

    // MARK: - Request plumbing

    private func perform(url: URL, method: String, jsonBody: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            } catch {
                throw CronDashboardError.malformedResponse("request body encode failed")
            }
        }
        AuthREST.bounded(&request)
        switch try await httpCredential() {
        case .none:
            break
        case .sessionTokenHeader(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .cookie(let cookie):
            request.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw CronDashboardError.transport(Redaction.safeErrorDescription(error))
        }
        guard data.count <= AuthREST.maxResponseBytes else {
            throw CronDashboardError.malformedResponse("cron response too large")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CronDashboardError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.log.error("dashboard cron: HTTP \(http.statusCode, privacy: .public) \(method, privacy: .public)")
            throw Self.mapStatus(http.statusCode, body: data)
        }
        return data
    }

    /// Status → typed error. Server error bodies are `{"detail": "…"}`
    /// (FastAPI) — the detail text is operator-facing, non-secret.
    static func mapStatus(_ status: Int, body: Data) -> CronDashboardError {
        let detail = errorDetail(body)
        switch status {
        case 401, 403:
            return .unauthorized
        case 404:
            return .notFound
        case 409:
            return .conflict(detail ?? "job is already running (claimed by another scheduler)")
        case 400, 422:
            return .invalidRequest(detail ?? "gateway rejected the request")
        case 424:
            return .registrationFailed(detail ?? "external scheduler registration failed")
        default:
            return .httpStatus(status)
        }
    }

    /// `{"detail": "…"}` / `{"detail": {…}}` / `{"error": "…"}` → text.
    static func errorDetail(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String, !detail.isEmpty { return detail }
        if let detail = object["detail"] {
            // FastAPI's structured partial-failure envelope (424) carries a
            // dict; render it compactly rather than dropping it.
            if let data = try? JSONSerialization.data(withJSONObject: detail),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}