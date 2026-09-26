import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI
@testable import HermesFleetApp

/// Card B — the Cron destination view model over the dashboard REST seam:
/// list/detail/create/edit/pause/resume/trigger/delete, delivery labels, and
/// the honest empty run-history state for `no_agent` script jobs.
@MainActor
final class CronDashboardModelTests: XCTestCase {

    // MARK: - Scripted seam

    private final class ScriptedDashboard: CronDashboardProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _jobs: [CronJobRecord]
        private var _runs: [String: [CronRunSession]]
        private var _calls: [String] = []
        private var _failNext: Error?
        private var _failNextDetail: Error?
        private var _triggerResult: Result<CronJobRecord, Error>?

        init(
            jobs: [CronJobRecord] = [
                CronJobRecord(
                    id: "job-1", name: "Morning briefing", prompt: "Summarize the fleet.",
                    schedule: CronSchedule(kind: "cron", expr: "0 7 * * *", display: "0 7 * * *"),
                    enabled: true, state: "scheduled", deliver: "local",
                    nextRunAt: "2026-09-05T07:00:00", lastRunAt: "2026-09-04T07:00:03",
                    lastStatus: "ok", repeatCompleted: 3,
                    latestExecution: CronExecution(id: "e1", status: "completed")),
                CronJobRecord(
                    id: "job-2", name: "Nightly script", prompt: "",
                    schedule: CronSchedule(kind: "cron", expr: "*/30 * * * *", display: "*/30 * * * *"),
                    enabled: false, state: "paused", noAgent: true, script: "pin.sh",
                    deliver: "bot-chat:default", pausedReason: "paused by user"),
            ],
            runs: [String: [CronRunSession]] = [
                "job-1": [CronRunSession(
                    id: "cron_job-1_1", title: "Cron: Morning briefing", source: "cron",
                    startedAt: 1_788_596_400, endedAt: 1_788_596_431, messageCount: 8,
                    profile: "default")],
            ]
        ) {
            _jobs = jobs
            _runs = runs
        }

        private func unlocked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var jobs: [CronJobRecord] { unlocked { _jobs } }
        var calls: [String] { unlocked { _calls } }

        func failNext(_ error: Error) { unlocked { _failNext = error } }
        /// Fails the DETAIL lookup only (the pane's refreshDetail also reads
        /// the list first, so a generic failNext would be consumed there).
        func failNextDetail(_ error: Error) { unlocked { _failNextDetail = error } }
        func setTriggerResult(_ result: Result<CronJobRecord, Error>) { unlocked { _triggerResult = result } }

        private func record(_ call: String) { unlocked { _calls.append(call) } }

        private func takeFailNext() -> Error? {
            unlocked {
                let error = _failNext
                _failNext = nil
                return error
            }
        }

        private func takeFailNextDetail() -> Error? {
            unlocked {
                let error = _failNextDetail
                _failNextDetail = nil
                return error
            }
        }

        func listJobs(profile: String?) async throws -> [CronJobRecord] {
            record("list:\(profile ?? "nil")")
            if let error = takeFailNext() { throw error }
            return unlocked { _jobs }
        }

        func job(id: String, profile: String?) async throws -> CronJobRecord {
            record("get:\(id)")
            if let error = takeFailNextDetail() { throw error }
            if let error = takeFailNext() { throw error }
            guard let job = unlocked({ _jobs.first { $0.id == id } }) else {
                throw CronDashboardError.notFound
            }
            // Wire fidelity: the REST DETAIL endpoint does not attach the
            // execution ledger (only list rows carry it) — the model must
            // compose it from its list snapshot.
            return job.withLatestExecution(nil)
        }

        func createJob(_ request: CronJobCreateRequest, profile: String?) async throws -> CronJobRecord {
            record("create:\(request.name)")
            if let error = takeFailNext() { throw error }
            let created = CronJobRecord(
                id: "job-new", name: request.name, prompt: request.prompt,
                schedule: CronSchedule(kind: "cron", expr: request.schedule, display: request.schedule),
                enabled: true, state: "scheduled", deliver: request.deliver)
            unlocked { _jobs.append(created) }
            return created
        }

        func updateJob(id: String, patch: CronJobPatch, profile: String?) async throws -> CronJobRecord {
            record("update:\(id)")
            if let error = takeFailNext() { throw error }
            let index = unlocked { _jobs.firstIndex { $0.id == id } }
            guard let index else { throw CronDashboardError.notFound }
            return unlocked {
                let old = _jobs[index]
                let updated = CronJobRecord(
                    id: old.id, name: patch.name ?? old.name,
                    prompt: patch.prompt ?? old.prompt, schedule: old.schedule,
                    scheduleDisplay: old.scheduleDisplay, enabled: old.enabled, state: old.state,
                    noAgent: old.noAgent, script: old.script, deliver: patch.deliver ?? old.deliver,
                    nextRunAt: old.nextRunAt, lastRunAt: old.lastRunAt, lastStatus: old.lastStatus,
                    latestExecution: old.latestExecution)
                _jobs[index] = updated
                // Wire fidelity: the store keeps the ledger (executions.db)
                // but the RESPONSE carries none — only list reads attach it.
                return updated.withLatestExecution(nil)
            }
        }

        func pauseJob(id: String, profile: String?) async throws -> CronJobRecord {
            try await setEnabled(id: id, enabled: false)
        }

        func resumeJob(id: String, profile: String?) async throws -> CronJobRecord {
            try await setEnabled(id: id, enabled: true)
        }

        private func setEnabled(id: String, enabled: Bool) async throws -> CronJobRecord {
            record(enabled ? "resume:\(id)" : "pause:\(id)")
            if let error = takeFailNext() { throw error }
            let index = unlocked { _jobs.firstIndex { $0.id == id } }
            guard let index else { throw CronDashboardError.notFound }
            return unlocked {
                let old = _jobs[index]
                let updated = CronJobRecord(
                    id: old.id, name: old.name, prompt: old.prompt, schedule: old.schedule,
                    scheduleDisplay: old.scheduleDisplay, enabled: enabled,
                    state: enabled ? "scheduled" : "paused",
                    noAgent: old.noAgent, script: old.script, deliver: old.deliver,
                    nextRunAt: old.nextRunAt, lastRunAt: old.lastRunAt, lastStatus: old.lastStatus,
                    latestExecution: old.latestExecution)
                _jobs[index] = updated
                // Wire fidelity: pause/resume responses carry NO ledger —
                // only list reads attach it (`cron/jobs.py` `list_jobs`).
                return updated.withLatestExecution(nil)
            }
        }

        func triggerJob(id: String, profile: String?) async throws -> CronJobRecord {
            record("trigger:\(id)")
            if let result = unlocked({ _triggerResult }) {
                switch result {
                case .success(let job): return job
                case .failure(let error): throw error
                }
            }
            if let error = takeFailNext() { throw error }
            return try await job(id: id, profile: profile)
        }

        func deleteJob(id: String, profile: String?) async throws {
            record("delete:\(id)")
            if let error = takeFailNext() { throw error }
            unlocked { _jobs.removeAll { $0.id == id } }
        }

        func runSessions(jobID: String, profile: String?, limit: Int) async throws -> [CronRunSession] {
            record("runs:\(jobID)")
            if let error = takeFailNext() { throw error }
            return unlocked { _runs[jobID] ?? [] }
        }

        func deliveryTargets() async throws -> [CronDeliveryTarget] {
            record("targets")
            if let error = takeFailNext() { throw error }
            return [
                CronDeliveryTarget(id: "local", name: "Local (save only)", homeTargetSet: true),
                CronDeliveryTarget(id: "bot-chat:default", name: "Bot Chat (default)", homeTargetSet: true),
            ]
        }
    }

    // MARK: - Tests

    func testStartLoadsJobsAndDeliveryTargets() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        XCTAssertEqual(model.jobs.map(\.id), ["job-1", "job-2"])
        XCTAssertEqual(model.deliveryTargets.map(\.id), ["local", "bot-chat:default"])
        XCTAssertEqual(model.deliveryLabel(for: "bot-chat:default"), "Bot Chat (default)")
        XCTAssertEqual(model.deliveryLabel(for: "telegram"), "telegram", "an unlisted operator target renders verbatim")
        XCTAssertNil(model.errorMessage)
    }

    func testListFailureSurfacesHonestly() async {
        let seam = ScriptedDashboard()
        seam.failNext(CronDashboardError.unauthorized)
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(model.errorMessage, "the gateway rejected the dashboard session — reconnect this gateway")
    }

    func testPauseAndResumeReplaceTheServerRow() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")

        await model.setJob("job-1", enabled: false, profile: "default")
        XCTAssertEqual(model.jobs.first { $0.id == "job-1" }?.enabled, false)
        XCTAssertEqual(model.jobs.first { $0.id == "job-1" }?.displayState, "paused")

        await model.setJob("job-1", enabled: true, profile: "default")
        XCTAssertEqual(model.jobs.first { $0.id == "job-1" }?.enabled, true)
        XCTAssertTrue(seam.calls.contains("pause:job-1"))
        XCTAssertTrue(seam.calls.contains("resume:job-1"))
    }

    func testTriggerSuccessNoticesAndRefreshes() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        await model.triggerJob("job-1", profile: "default")
        XCTAssertEqual(model.notice, "Run requested — the job is firing now.")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(seam.calls.contains("trigger:job-1"))
    }

    func testTriggerConflictIsANoticeNotAnError() async {
        let seam = ScriptedDashboard()
        seam.setTriggerResult(.failure(
            CronDashboardError.conflict("Job is already running or was claimed by another scheduler")))
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        await model.triggerJob("job-1", profile: "default")
        XCTAssertEqual(model.notice, "Job is already running or was claimed by another scheduler")
        XCTAssertNil(model.errorMessage)
    }

    func testCreateAppendsAndFailureKeepsFormError() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")

        let ok = await model.createJob(
            CronJobCreateRequest(name: "Evening recap", schedule: "every day at 21:00", prompt: "Recap."),
            profile: "default")
        XCTAssertTrue(ok)
        XCTAssertTrue(model.jobs.contains { $0.name == "Evening recap" })

        seam.failNext(CronDashboardError.invalidRequest("Invalid schedule"))
        let failed = await model.createJob(
            CronJobCreateRequest(name: "Bad", schedule: "whenever", prompt: "x"), profile: "default")
        XCTAssertFalse(failed)
        XCTAssertEqual(model.formError, "Invalid schedule")
    }

    func testUpdateEditsInPlaceWithSameIdentity() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")

        let ok = await model.updateJob(
            id: "job-1", patch: CronJobPatch(name: "Renamed briefing"), profile: "default")
        XCTAssertTrue(ok)
        XCTAssertEqual(model.jobs.first { $0.id == "job-1" }?.name, "Renamed briefing")
        XCTAssertEqual(model.jobs.count, 2, "edit must not add or re-create rows")
    }

    func testDeleteRemovesRowAndClearsDetail() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        await model.loadDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.detail?.id, "job-1")

        let ok = await model.deleteJob("job-1", profile: "default")
        XCTAssertTrue(ok)
        XCTAssertFalse(model.jobs.contains { $0.id == "job-1" })
        XCTAssertNil(model.detail)
    }

    func testDetailLoadsRunsAndScriptJobHasHonestEmptyHistory() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")

        await model.refreshDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.detail?.name, "Morning briefing")
        XCTAssertEqual(model.detailRuns.map(\.id), ["cron_job-1_1"])
        XCTAssertNil(model.detail?.latestExecution, "wire fidelity: the detail endpoint carries no ledger")
        XCTAssertEqual(model.ledger(for: "job-1")?.status, "completed",
                       "the pane composes the ledger from its list snapshot")

        await model.refreshDetail(id: "job-2", profile: "default")
        XCTAssertTrue(model.detailRuns.isEmpty, "no_agent script jobs have no run sessions by design")
        XCTAssertTrue(model.detail?.noAgent == true)
        XCTAssertTrue(seam.calls.contains("runs:job-2"))
    }

    func testDetailFailureSurfacesHonestly() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        seam.failNextDetail(CronDashboardError.notFound)
        await model.refreshDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.detailError, "job not found on this gateway")
        XCTAssertNil(model.detail)
    }

    /// The REST detail endpoint carries no ledger; the pane composes it from
    /// the list snapshot it already holds (and shows nothing when the job has
    /// never fired).
    func testLedgerComposesFromListSnapshot() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        await model.refreshDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.ledger(for: "job-1")?.id, "e1")
        XCTAssertNil(model.ledger(for: "job-2"), "a job that never fired has no ledger")
        XCTAssertNil(model.ledger(for: "missing-job"), "an unknown job has no ledger")
    }

    /// Review round 1 regression: pause/resume/edit responses carry NO
    /// `latest_execution` — the server attaches the ledger to LIST rows only.
    /// Replacing the row with the ledger-less response made the detail screen
    /// fabricate "this job has not fired" for a job that demonstrably has,
    /// while the same screen still showed Last run / Last status.
    func testLedgerSurvivesLedgerlessMutationResponses() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        await model.refreshDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.ledger(for: "job-1")?.id, "e1", "precondition: the ledger is visible")

        // Non-vacuity guard: the mutation responses the wire really sends are
        // ledger-less (a seam that leaked the ledger would let a regressed
        // model pass this test).
        let probe = ScriptedDashboard()
        let pauseResponse: CronJobRecord? = try? await probe.pauseJob(id: "job-1", profile: "default")
        XCTAssertNil(pauseResponse?.latestExecution, "pause responses carry no ledger (wire shape)")
        let updateResponse: CronJobRecord? = try? await probe.updateJob(
            id: "job-1", patch: CronJobPatch(name: "probe"), profile: "default")
        XCTAssertNil(updateResponse?.latestExecution, "PUT responses carry no ledger (wire shape)")

        await model.setJob("job-1", enabled: false, profile: "default")
        XCTAssertEqual(model.jobs.first { $0.id == "job-1" }?.enabled, false)
        XCTAssertEqual(model.ledger(for: "job-1")?.id, "e1", "pause must not erase the ledger")

        await model.setJob("job-1", enabled: true, profile: "default")
        XCTAssertEqual(model.ledger(for: "job-1")?.id, "e1", "resume must not erase the ledger")

        await model.updateJob(
            id: "job-1", patch: CronJobPatch(name: "Renamed briefing"), profile: "default")
        XCTAssertEqual(model.jobs.first { $0.id == "job-1" }?.name, "Renamed briefing")
        XCTAssertEqual(model.ledger(for: "job-1")?.id, "e1", "edit must not erase the ledger")

        // Nothing is fabricated either: a job that never fired keeps its
        // honest empty state across mutations.
        await model.setJob("job-2", enabled: true, profile: "default")
        XCTAssertNil(model.ledger(for: "job-2"), "a job that never fired still has no ledger")
    }

    // MARK: - OCR review round (Cron surfaces)

    /// [medium] The last-run treatment follows `last_status`, never the job
    /// `state`: the captured live list row pairs `state: "scheduled"` with
    /// `last_status: "blocked_config"` + `failure_streak: 2` (a scheduled job
    /// whose last run was blocked), while a completed one-shot carries a
    /// terminal STATE and a healthy status.
    func testFailureStatusFollowsTheStatusNotTheState() {
        let blocked = CronJobRecord(
            id: "0d6e0654a3bf", name: "fleet-pin-agent", prompt: "say pin",
            schedule: CronSchedule(kind: "cron", expr: "0 3 * * *", display: "0 3 * * *"),
            enabled: true, state: "scheduled", deliver: "local",
            lastStatus: "blocked_config", failureStreak: 2)
        XCTAssertFalse(blocked.isTerminalOrError, "state is `scheduled` — not terminal")
        XCTAssertTrue(blocked.isFailureStatus, "the last run was blocked at preflight")

        let completedOneShot = CronJobRecord(
            id: "job-once", name: "one shot", prompt: "p",
            schedule: CronSchedule(kind: "once", expr: "", display: "once"),
            enabled: false, state: "completed", deliver: "local", lastStatus: "ok")
        XCTAssertTrue(completedOneShot.isTerminalOrError)
        XCTAssertFalse(completedOneShot.isFailureStatus, "a successful one-shot is not a failure")

        for status in ["error", "failed", "failure", "fire_failed", "blocked_config", " FAILED "] {
            let job = CronJobRecord(
                id: "j", name: "n", schedule: CronSchedule(kind: "cron", expr: "* * * * *", display: "* * * * *"),
                enabled: true, state: "scheduled", deliver: "local", lastStatus: status)
            XCTAssertTrue(job.isFailureStatus, status)
        }
        for status in ["ok", "delivery_queued", "delivery_failed", "", "   "] {
            let job = CronJobRecord(
                id: "j", name: "n", schedule: CronSchedule(kind: "cron", expr: "* * * * *", display: "* * * * *"),
                enabled: true, state: "scheduled", deliver: "local", lastStatus: status)
            XCTAssertFalse(job.isFailureStatus, "not a failure status: '\(status)'")
        }
        let neverRan = CronJobRecord(
            id: "j", name: "n", schedule: CronSchedule(kind: "cron", expr: "* * * * *", display: "* * * * *"),
            enabled: true, state: "scheduled", deliver: "local", lastStatus: nil)
        XCTAssertFalse(neverRan.isFailureStatus)
    }

    /// [low] The hoisted `CronTimestamp` formatters must keep parsing every
    /// wire shape (rendered from view bodies, so repeated calls must stay
    /// stable), and an unparsable value still renders verbatim.
    func testCronTimestampDisplayParsesWireShapesDeterministically() {
        // The naive shape is interpreted as LOCAL wall time → timezone-proof.
        XCTAssertEqual(CronTimestamp.display("2026-09-05T07:00:00"), "Sep 5, 07:00")
        XCTAssertEqual(CronTimestamp.display("2026-09-05T07:00:00"), "Sep 5, 07:00",
                       "a repeated render-path call stays stable (shared formatters)")
        // The live gateway shape (fractional seconds + offset) parses; its
        // exact local render is timezone-dependent, so compare the two
        // splitters against each other instead.
        let fractional = CronTimestamp.display("2026-09-17T01:36:21.643921-05:00")
        XCTAssertNotNil(fractional)
        XCTAssertEqual(fractional, CronTimestamp.display("2026-09-17T01:36:21-05:00"),
                       "fractional and plain ISO splitters agree on the instant")
        XCTAssertEqual(CronTimestamp.display("not a date"), "not a date", "unparsable renders verbatim")
        XCTAssertNil(CronTimestamp.display(nil))
        XCTAssertNil(CronTimestamp.display(""))
        let epoch = CronTimestamp.display(epochSeconds: 1_788_596_400)
        XCTAssertNotNil(epoch)
        XCTAssertEqual(epoch, CronTimestamp.display(epochSeconds: 1_788_596_400))
        XCTAssertNil(CronTimestamp.display(epochSeconds: 0))
        XCTAssertNil(CronTimestamp.display(epochSeconds: nil))
    }

    /// [low] The panes render BOTH the notice and the error bar when both are
    /// non-nil, so each terminal outcome replaces the other banner.
    func testMutationOutcomesReplaceTheOppositeBanner() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")

        let deleted = await model.deleteJob("job-2", profile: "default")
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.notice, "Job deleted.")
        XCTAssertNil(model.errorMessage)

        seam.failNext(CronDashboardError.unauthorized)
        let toggled = await model.setJob("job-1", enabled: false, profile: "default")
        XCTAssertFalse(toggled)
        XCTAssertEqual(model.errorMessage, "the gateway rejected the dashboard session — reconnect this gateway")
        XCTAssertNil(model.notice, "a fresh failure must not sit beside the stale success notice")

        let recovered = await model.setJob("job-1", enabled: false, profile: "default")
        XCTAssertTrue(recovered)
        XCTAssertNil(model.errorMessage, "a fresh success clears the stale error")
        XCTAssertNil(model.notice)
    }

    /// The trigger's two honest outcomes are mutually exclusive too (the 409
    /// claim is a NOTICE, every other failure is an error).
    func testTriggerNoticeAndFailureAreExclusive() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")

        seam.failNext(CronDashboardError.unauthorized)
        await model.triggerJob("job-1", profile: "default")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.notice)

        seam.setTriggerResult(.failure(CronDashboardError.conflict("already running")))
        await model.triggerJob("job-1", profile: "default")
        XCTAssertEqual(model.notice, "already running")
        XCTAssertNil(model.errorMessage, "the conflict notice clears the previous error")
    }

    /// A failed list read is a terminal outcome as well: it supersedes the last
    /// success notice (a stale "Job created." beside a fresh error was the
    /// reporting symptom).
    func testFailedListReadSupersedesTheSuccessNotice() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        let deleted = await model.deleteJob("job-2", profile: "default")
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.notice, "Job deleted.")

        seam.failNext(CronDashboardError.transport("boom"))
        await model.refresh(profile: "default")
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.errorMessage, "boom")
    }

    /// [low] The model is shared per gateway, so a detail read for a DIFFERENT
    /// job must drop the previous job's record and runs — including when the
    /// requested read fails (otherwise the previous job's detail screen stands
    /// in permanently for the missing one).
    func testDetailClearsThePreviousJobWhenSwitching() async {
        let seam = ScriptedDashboard()
        let model = CronDashboardModel(gatewayID: GatewayID(rawValue: "g1"), dashboard: seam)
        await model.start(profile: "default")
        await model.refreshDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.detail?.id, "job-1")
        XCTAssertFalse(model.detailRuns.isEmpty, "precondition: job-1 carries a run")

        seam.failNextDetail(CronDashboardError.notFound)
        // refreshDetail is the screen's own entry point and drops the previous
        // record BEFORE its async reads (asserted once the call settles; the
        // view additionally guards on the requested id while they run).
        await model.refreshDetail(id: "job-2", profile: "default")
        XCTAssertNil(model.detail, "the previous job's record must not stand in for the requested one")
        XCTAssertTrue(model.detailRuns.isEmpty, "nor its run history")
        XCTAssertEqual(model.detailError, "job not found on this gateway")

        // The same read for the SAME job keeps its record while refreshing
        // (a pull-to-refresh must not blank the screen).
        await model.refreshDetail(id: "job-1", profile: "default")
        XCTAssertEqual(model.detail?.id, "job-1")
    }

    /// [medium, medium] The create form's scope comes from the machine's BOUND
    /// section: the section's resolved profile (never a hardcoded `default`),
    /// and nothing at all when no section is bound — the + stays disabled
    /// instead of opening an empty sheet.
    func testCreateScopeFollowsTheBoundSectionProfile() async {
        let gateway = GatewayID(rawValue: "g1")
        let seam = ScriptedDashboard()

        let cache = CronSectionCache()
        XCTAssertNil(cache.createScope(for: gateway), "no section bound yet → no scope")

        let model = cache.model(for: gateway, seam: seam)
        cache.retain(gateway)
        XCTAssertNil(cache.createScope(for: gateway), "bound but never loaded → no resolved profile")

        await model.start(profile: "researcher")
        let scope = cache.createScope(for: gateway)
        XCTAssertEqual(scope?.profile.rawValue, "researcher",
                       "the scope follows the section's resolved profile — never `default`")
        XCTAssertTrue(scope?.model === model, "the scope reuses the section's model")

        // A model that exists in the cache without a retain (created on demand)
        // is not a scope either: the sheet must ride a retained section.
        let other = CronSectionCache()
        _ = other.model(for: gateway, seam: seam)
        XCTAssertNil(other.createScope(for: gateway), "an unretained model is not a section scope")
    }
}
