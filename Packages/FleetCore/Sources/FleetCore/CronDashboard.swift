import Foundation

/// Card B — the dashboard REST cron surface (`/api/cron/jobs*`).
///
/// Wire ground truth (hermes-agent, verified in-source AND captured live
/// against the dev gateway; see `build/b-cron-evidence/`):
/// - `GET    /api/cron/jobs?profile=<p|all>`  → JSON ARRAY of job records
///   (`_list_cron_jobs_sync` → `list_jobs` → `_normalize_job_record` +
///   `latest_execution` + the `_annotate_cron_job` profile fields).
/// - `GET    /api/cron/jobs/{id}?profile=<p>` → one job record (404 unknown).
///   The execution ledger (`latest_execution`) is attached by the LIST
///   endpoint only — a detail read carries it nil.
/// - `POST   /api/cron/jobs?profile=<p>`      → created job record
///   (body: CronJobCreate — `{name, schedule, prompt|skills|script, deliver,
///   no_agent, …}`; 400 on validation errors, 424 on scheduler-registration
///   partial failure).
/// - `PUT    /api/cron/jobs/{id}?profile=<p>` → updated job record,
///   body `{"updates": {…}}`; identity (id) is PRESERVED (never a
///   delete-recreate).
/// - `POST   /api/cron/jobs/{id}/pause|resume|trigger` → the job record.
///   `trigger` claims the job atomically: 409 "already running" when another
///   scheduler won the claim; a one-shot that completed may answer
///   `{…, enabled: false, state: "completed"}`.
/// - `DELETE /api/cron/jobs/{id}?profile=<p>` → `{"ok": true}`.
/// - `GET    /api/cron/jobs/{id}/runs?profile=<p>&limit=N` →
///   `{"runs": [SessionInfo…], "limit": N}`. Runs are agent run SESSIONS;
///   `no_agent` script jobs short-circuit BEFORE the session store
///   (`cron/scheduler.py` pre-session path), so an empty list there is
///   expected — the execution ledger (`latestExecution`) is their history.
/// - `GET    /api/cron/delivery-targets` → `{"targets": [{id, name,
///   home_target_set, home_env_var}]}` (implicit `local` + configured
///   platforms; a platform without a cron home channel is still listed with
///   `home_target_set: false` so the UI can say so).
///
/// Auth is the dashboard session credential (`X-Hermes-Session-Token` header
/// or the password-login cookie) — the SAME resolution the kanban REST
/// fetches use; the WS `cron.manage` vocabulary is NOT sufficient here
/// (it has no update/edit and no run action — err 4016).
public struct CronJobRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let prompt: String
    public let schedule: CronSchedule
    public let scheduleDisplay: String
    public let enabled: Bool
    public let state: String
    public let noAgent: Bool
    public let script: String?
    public let skills: [String]
    public let model: String?
    public let provider: String?
    public let deliver: String
    public let failureDeliver: String?
    public let nextRunAt: String?
    public let lastRunAt: String?
    public let lastStatus: String?
    public let lastError: String?
    public let lastDeliveryError: String?
    public let lastDeliveryUnverified: String?
    public let failureStreak: Int?
    public let pausedAt: String?
    public let pausedReason: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let repeatTimes: Int?
    public let repeatCompleted: Int?
    /// Profile attribution from the dashboard's per-profile annotation
    /// (`_annotate_cron_job`) — present on every REST row.
    public let profile: String?
    public let profileName: String?
    public let isDefaultProfile: Bool
    /// The always-present execution ledger row (works for script AND agent
    /// jobs, including failed/preflight-blocked runs).
    public let latestExecution: CronExecution?

    public init(
        id: String,
        name: String,
        prompt: String = "",
        schedule: CronSchedule,
        scheduleDisplay: String? = nil,
        enabled: Bool = true,
        state: String = "",
        noAgent: Bool = false,
        script: String? = nil,
        skills: [String] = [],
        model: String? = nil,
        provider: String? = nil,
        deliver: String = "local",
        failureDeliver: String? = nil,
        nextRunAt: String? = nil,
        lastRunAt: String? = nil,
        lastStatus: String? = nil,
        lastError: String? = nil,
        lastDeliveryError: String? = nil,
        lastDeliveryUnverified: String? = nil,
        failureStreak: Int? = nil,
        pausedAt: String? = nil,
        pausedReason: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        repeatTimes: Int? = nil,
        repeatCompleted: Int? = nil,
        profile: String? = nil,
        profileName: String? = nil,
        isDefaultProfile: Bool = false,
        latestExecution: CronExecution? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.scheduleDisplay = scheduleDisplay ?? schedule.display
        self.enabled = enabled
        self.state = state
        self.noAgent = noAgent
        self.script = script
        self.skills = skills
        self.model = model
        self.provider = provider
        self.deliver = deliver
        self.failureDeliver = failureDeliver
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastDeliveryError = lastDeliveryError
        self.lastDeliveryUnverified = lastDeliveryUnverified
        self.failureStreak = failureStreak
        self.pausedAt = pausedAt
        self.pausedReason = pausedReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.repeatTimes = repeatTimes
        self.repeatCompleted = repeatCompleted
        self.profile = profile
        self.profileName = profileName
        self.isDefaultProfile = isDefaultProfile
        self.latestExecution = latestExecution
    }

    /// The state the operator-facing chip renders. The wire already derives
    /// this (`effective_job_state`: an ENABLED job must never display
    /// paused); an empty state falls back to the enabled flag rather than
    /// claiming a state the record does not carry.
    public var displayState: String {
        state.isEmpty ? (enabled ? "scheduled" : "paused") : state
    }

    /// True when the row's state is one of the terminal/error shapes the UI
    /// renders with a warning tone.
    public var isTerminalOrError: Bool {
        ["error", "failed", "fire_failed", "completed"].contains(displayState.lowercased())
    }

    /// True when `last_status` describes a last run the operator must read as a
    /// failure. This key is the STATUS — never the job `state`: the two are
    /// independent on the wire. The captured live list row carries
    /// `state: "scheduled"` with `last_status: "blocked_config"` and
    /// `failure_streak: 2` (scheduled for its next run, last run blocked),
    /// while a one-shot that ran to completion has a terminal STATE with
    /// `last_status: "ok"`.
    ///
    /// Vocabulary — `cron/jobs.py` `mark_job_run` writes the derived values
    /// `ok` | `error` | `delivery_failed`, plus explicit overrides such as
    /// `blocked_config` (preflight block: no LLM call) and `fire_failed` (the
    /// scheduler's forward-failure stamp). The gateway's own doctor
    /// (`hermes_cli/cron.py`) treats every status outside
    /// {ok, delivery_failed, delivery_queued} as a failed last run; Fleet keeps
    /// the deny-list below so an unrecognized future value renders neutrally
    /// instead of claiming a failure it cannot name.
    public var isFailureStatus: Bool {
        guard let lastStatus else { return false }
        let status = lastStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !status.isEmpty else { return false }
        return Self.failureStatuses.contains(status)
    }

    /// The `last_status` values the UI renders with the warning treatment:
    /// BotRoutinesView's `runStatusLine` set plus the live `blocked_config`.
    private static let failureStatuses: Set<String> = [
        "failed", "error", "failure", "fire_failed", "blocked_config",
    ]

    /// A copy carrying the given execution ledger (`nil` clears it).
    ///
    /// The wire attaches `latest_execution` to LIST rows only
    /// (`cron/jobs.py` `list_jobs`): detail reads, pause/resume, PUT, and
    /// trigger answers all omit it. Anything that must reproduce such a
    /// response — the model's merge path, wire-faithful seams — goes through
    /// this so the omission is explicit instead of silently destructive.
    public func withLatestExecution(_ execution: CronExecution?) -> CronJobRecord {
        CronJobRecord(
            id: id,
            name: name,
            prompt: prompt,
            schedule: schedule,
            scheduleDisplay: scheduleDisplay,
            enabled: enabled,
            state: state,
            noAgent: noAgent,
            script: script,
            skills: skills,
            model: model,
            provider: provider,
            deliver: deliver,
            failureDeliver: failureDeliver,
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastStatus: lastStatus,
            lastError: lastError,
            lastDeliveryError: lastDeliveryError,
            lastDeliveryUnverified: lastDeliveryUnverified,
            failureStreak: failureStreak,
            pausedAt: pausedAt,
            pausedReason: pausedReason,
            createdAt: createdAt,
            updatedAt: updatedAt,
            repeatTimes: repeatTimes,
            repeatCompleted: repeatCompleted,
            profile: profile,
            profileName: profileName,
            isDefaultProfile: isDefaultProfile,
            latestExecution: execution
        )
    }
}

/// The job's schedule object as stored (`{kind, expr, display}` —
/// e.g. `{kind: "cron", expr: "0 3 * * *", display: "0 3 * * *"}`).
public struct CronSchedule: Hashable, Sendable {
    public let kind: String
    public let expr: String
    public let display: String

    public init(kind: String, expr: String, display: String) {
        self.kind = kind
        self.expr = expr
        self.display = display
    }
}

/// One row of the per-profile execution ledger (`cron/executions.db`) as
/// attached to every job record. Always present when the job has ever been
/// attempted; `finishedAt == nil` means the run is still in flight (or the
/// process died mid-run).
public struct CronExecution: Hashable, Sendable {
    public let id: String
    public let status: String
    public let source: String?
    public let pid: Int?
    public let claimedAt: String?
    public let startedAt: String?
    public let finishedAt: String?
    public let error: String?
    public let deliveryOutcome: String?
    public let scheduledInstant: String?

    public init(
        id: String,
        status: String,
        source: String? = nil,
        pid: Int? = nil,
        claimedAt: String? = nil,
        startedAt: String? = nil,
        finishedAt: String? = nil,
        error: String? = nil,
        deliveryOutcome: String? = nil,
        scheduledInstant: String? = nil
    ) {
        self.id = id
        self.status = status
        self.source = source
        self.pid = pid
        self.claimedAt = claimedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.deliveryOutcome = deliveryOutcome
        self.scheduledInstant = scheduledInstant
    }
}

/// One AGENT run session of a cron job (`GET …/runs`), in the dashboard's
/// `list_sessions_rich` row shape. `no_agent` script jobs produce none by
/// design — the UI must show the honest empty state instead of inventing
/// history.
public struct CronRunSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let source: String?
    /// Epoch seconds (the sessions table's shape).
    public let startedAt: Double?
    public let endedAt: Double?
    public let lastActive: Double?
    public let messageCount: Int?
    public let preview: String?
    public let profile: String?
    /// Server-derived: ended_at == nil and last activity < 300s old.
    public let isActive: Bool
    public let archived: Bool

    public init(
        id: String,
        title: String,
        source: String? = nil,
        startedAt: Double? = nil,
        endedAt: Double? = nil,
        lastActive: Double? = nil,
        messageCount: Int? = nil,
        preview: String? = nil,
        profile: String? = nil,
        isActive: Bool = false,
        archived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.preview = preview
        self.profile = profile
        self.isActive = isActive
        self.archived = archived
    }
}

/// One delivery option for the job form: the implicit `local` (save only)
/// plus every configured gateway platform. `homeTargetSet == false` means the
/// platform has no cron home channel configured — say so, never silently
/// fail the delivery.
public struct CronDeliveryTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let homeTargetSet: Bool
    public let homeEnvVar: String?

    public init(id: String, name: String, homeTargetSet: Bool, homeEnvVar: String? = nil) {
        self.id = id
        self.name = name
        self.homeTargetSet = homeTargetSet
        self.homeEnvVar = homeEnvVar
    }
}

/// A create payload for `POST /api/cron/jobs` (`CronJobCreate`). The form
/// flavor carries a prompt; the dashboard validates that a job has a prompt,
/// a skill, or a script, and that the schedule parses.
public struct CronJobCreateRequest: Hashable, Sendable {
    public var name: String
    public var schedule: String
    public var prompt: String
    /// `local` keeps the job save-only; anything else names a platform target
    /// (see `CronDeliveryTarget`).
    public var deliver: String
    /// Script flavor (`no_agent: true` + a script path): the gateway runs the
    /// script directly, with no agent turn and no run session. The Cron
    /// destination's form creates prompt jobs; this rides the same contract
    /// (the live contract check creates a script job so its trigger executes
    /// without a configured provider).
    public var script: String?
    public var noAgent: Bool

    public init(
        name: String = "",
        schedule: String = "",
        prompt: String = "",
        deliver: String = "local",
        script: String? = nil,
        noAgent: Bool = false
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.deliver = deliver
        self.script = script
        self.noAgent = noAgent
    }

    /// Client-side validity (the server re-validates): a job needs a name, a
    /// schedule, and an execution body — a prompt (this form's flavor) or a
    /// script.
    public var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSchedule = !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasScript = !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasSchedule && (hasPrompt || hasScript)
    }
}

/// An update payload for `PUT /api/cron/jobs/{id}` — sent as
/// `{"updates": {…}}` with ONLY the changed keys (absent keys keep their
/// stored values; `update_job` merges). Identity is preserved: the same job
/// id comes back.
public struct CronJobPatch: Hashable, Sendable {
    public var name: String?
    public var schedule: String?
    public var prompt: String?
    public var deliver: String?

    public init(name: String? = nil, schedule: String? = nil, prompt: String? = nil, deliver: String? = nil) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.deliver = deliver
    }

    public var isEmpty: Bool {
        name == nil && schedule == nil && prompt == nil && deliver == nil
    }

    /// The `updates` object, trimmed and with blanks dropped (a blank field
    /// means "leave it alone", never "clear it").
    public var wireUpdates: [String: String] {
        var out: [String: String] = [:]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let schedule, !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["schedule"] = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["prompt"] = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let deliver, !deliver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["deliver"] = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}

/// Typed failures of the dashboard cron surface. Non-secret by construction
/// (server `detail` strings are operator-facing text; the transport errors
/// are Redaction-safe).
public enum CronDashboardError: Error, Sendable, Equatable, LocalizedError {
    /// 401 — the dashboard session credential was missing/rejected.
    case unauthorized
    /// 404 — the job (or profile) does not exist.
    case notFound
    /// 409 — `trigger` lost the atomic claim (another scheduler is running it).
    case conflict(String)
    /// 400 / 422 — the server rejected the payload; `detail` is its message.
    case invalidRequest(String)
    /// 424 — the job was saved but external scheduler registration failed
    /// (the structured partial-failure envelope).
    case registrationFailed(String)
    /// Any other non-2xx status.
    case httpStatus(Int)
    /// The body was not the expected shape.
    case malformedResponse(String)
    /// Transport-level failure (timeout, connection closed, …).
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "the gateway rejected the dashboard session — reconnect this gateway"
        case .notFound:
            return "job not found on this gateway"
        case .conflict(let detail):
            return detail.isEmpty ? "job is already running (claimed by another scheduler)" : detail
        case .invalidRequest(let detail):
            return detail
        case .registrationFailed(let detail):
            return "job saved, but scheduler registration failed: \(detail)"
        case .httpStatus(let code):
            return "gateway returned HTTP \(code)"
        case .malformedResponse(let detail):
            return "malformed gateway response (\(detail))"
        case .transport(let detail):
            return detail
        }
    }

    /// True when the trigger lost its claim — the UI says "already running"
    /// rather than showing a failure.
    public var isAlreadyRunning: Bool {
        if case .conflict = self { return true }
        return false
    }
}

/// Card B seam: the dashboard REST cron surface. Lives in FleetCore so
/// FleetUI never imports FleetNetworking (M0 guard); the concrete client is
/// injected at the composition root per gateway.
///
/// PROFILE SCOPING: every call carries the profile whose cron store is
/// addressed (`?profile=`; `all` lists across profiles — rows then carry
/// their own `profile` attribution). `nil` means the profile the job is
/// stored under as discovered by the dashboard.
public protocol CronDashboardProviding: Sendable {
    /// `GET /api/cron/jobs?profile=` — every job (paused included; the REST
    /// list does not hide disabled jobs). Rows carry the execution ledger
    /// (`latest_execution`); the detail endpoint does NOT.
    func listJobs(profile: String?) async throws -> [CronJobRecord]

    /// `GET /api/cron/jobs/{id}?profile=` — one job, full record. NOTE: the
    /// ledger (`latest_execution`) is attached by the LIST endpoint only
    /// (`cron/jobs.py` `list_jobs`); a detail read has it nil, so UIs compose
    /// the ledger from their list snapshot.
    func job(id: String, profile: String?) async throws -> CronJobRecord

    /// `POST /api/cron/jobs?profile=` — create.
    @discardableResult
    func createJob(_ request: CronJobCreateRequest, profile: String?) async throws -> CronJobRecord

    /// `PUT /api/cron/jobs/{id}?profile=` — edit in place (identity preserved).
    @discardableResult
    func updateJob(id: String, patch: CronJobPatch, profile: String?) async throws -> CronJobRecord

    /// `POST /api/cron/jobs/{id}/pause?profile=`.
    @discardableResult
    func pauseJob(id: String, profile: String?) async throws -> CronJobRecord

    /// `POST /api/cron/jobs/{id}/resume?profile=`.
    @discardableResult
    func resumeJob(id: String, profile: String?) async throws -> CronJobRecord

    /// `POST /api/cron/jobs/{id}/trigger?profile=` — run now (atomic claim;
    /// throws `.conflict` when another scheduler already claimed it).
    @discardableResult
    func triggerJob(id: String, profile: String?) async throws -> CronJobRecord

    /// `DELETE /api/cron/jobs/{id}?profile=`.
    func deleteJob(id: String, profile: String?) async throws

    /// `GET /api/cron/jobs/{id}/runs?profile=&limit=` — agent run sessions,
    /// newest first (empty for `no_agent` script jobs by design).
    func runSessions(jobID: String, profile: String?, limit: Int) async throws -> [CronRunSession]

    /// `GET /api/cron/delivery-targets` — the delivery dropdown's options.
    func deliveryTargets() async throws -> [CronDeliveryTarget]
}

/// Fail-closed default for gateways without a dashboard cron surface: every
/// call throws instead of pretending the gateway answered (the
/// `UnsupportedApprovals` discipline).
public struct UnsupportedCronDashboard: CronDashboardProviding {
    public init() {}

    public func listJobs(profile: String?) async throws -> [CronJobRecord] {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func job(id: String, profile: String?) async throws -> CronJobRecord {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func createJob(_ request: CronJobCreateRequest, profile: String?) async throws -> CronJobRecord {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func updateJob(id: String, patch: CronJobPatch, profile: String?) async throws -> CronJobRecord {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func pauseJob(id: String, profile: String?) async throws -> CronJobRecord {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func resumeJob(id: String, profile: String?) async throws -> CronJobRecord {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func triggerJob(id: String, profile: String?) async throws -> CronJobRecord {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func deleteJob(id: String, profile: String?) async throws {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func runSessions(jobID: String, profile: String?, limit: Int) async throws -> [CronRunSession] {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }

    public func deliveryTargets() async throws -> [CronDeliveryTarget] {
        throw CronDashboardError.transport("gateway has no dashboard cron surface")
    }
}

/// Compact display formatting for the ISO-8601 instants the cron records
/// carry (`next_run_at`, ledger timestamps) and the epoch-seconds run rows.
/// Deterministic; an unparsable value renders verbatim rather than a
/// fabricated date.
public enum CronTimestamp {
    /// "Sep 17, 03:00" in the user's locale; `nil`/blank/unparsable render
    /// the raw string (or nil).
    public static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = parse(raw) else { return raw }
        return displayFormatter.string(from: date)
    }

    /// Epoch-seconds display for run rows.
    public static func display(epochSeconds: Double?) -> String? {
        guard let epochSeconds, epochSeconds > 0 else { return nil }
        return displayFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }

    /// ISO-8601 parse with the fractional-seconds fallback the gateway's
    /// `datetime.now().isoformat()` values need.
    ///
    /// The splitters are shared statics: building a formatter is comparatively
    /// expensive and this parser runs on the render path (every row's
    /// next-fire line, the detail screen's schedule/ledger rows).
    /// `nonisolated(unsafe)`: `ISO8601DateFormatter` is not `Sendable`, but
    /// these instances are only ever used for parsing, which is thread-safe.
    static func parse(_ raw: String) -> Date? {
        if let date = isoWithFractionalSeconds.date(from: raw) { return date }
        if let date = isoWithoutFractionalSeconds.date(from: raw) { return date }
        // Naive local timestamps ("2026-09-05T07:00:00" — the scripted
        // fixtures' shape): interpret as local wall time.
        if !raw.hasSuffix("Z"), !raw.contains("+") {
            return naiveLocalFormatter.date(from: raw)
        }
        return nil
    }

    nonisolated(unsafe) private static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let naiveLocalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()
}