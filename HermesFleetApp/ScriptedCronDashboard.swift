import Foundation
import FleetCore

/// Card B (DEBUG simulator only): scripted dashboard cron seam — fixture jobs
/// with in-memory mutations so the Cron destination is fully walkable
/// (list → detail → edit → pause/resume → run now → delete-with-confirm →
/// history) without a live gateway. Presentation data only; every mutation
/// answers the same record shapes the REST contract returns — including the
/// wire's ledger discipline: `latest_execution` rides LIST reads only, so
/// mutation/detail responses omit it and the pane must compose it from its
/// list snapshot (review round 1 regression).
///
/// Fixture ids keep the `script-cron-*` prefix the UI suites address
/// (`cron.row.script-cron-1`, …); `script-cron-3` is the `no_agent` script
/// flavor so the honest "script jobs have no run sessions" empty state is
/// reachable in the simulator.
final class ScriptedCronDashboard: CronDashboardProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [CronJobRecord]
    private var runsByJob: [String: [CronRunSession]]

    init(gatewayID: GatewayID) {
        if gatewayID.rawValue == "arch" {
            // The outage gateway gets no jobs (honest partial-fleet state).
            jobs = []
            runsByJob = [:]
        } else {
            jobs = [
                CronJobRecord(
                    id: "script-cron-1", name: "Fleet morning briefing",
                    prompt: "Summarize fleet activity since yesterday and flag stuck cards.",
                    schedule: CronSchedule(kind: "cron", expr: "0 7 * * *", display: "every day at 07:00"),
                    scheduleDisplay: "every day at 07:00",
                    enabled: true, state: "scheduled", deliver: "local",
                    nextRunAt: "2026-09-05T07:00:00", lastRunAt: "2026-09-04T07:00:03",
                    lastStatus: "ok", failureStreak: 0, repeatCompleted: 4,
                    profile: "default", profileName: "default", isDefaultProfile: true,
                    latestExecution: CronExecution(
                        id: "exec-script-cron-1", status: "completed", source: "builtin", pid: 4242,
                        claimedAt: "2026-09-04T07:00:00", startedAt: "2026-09-04T07:00:01",
                        finishedAt: "2026-09-04T07:00:03", deliveryOutcome: "delivered")),
                CronJobRecord(
                    id: "script-cron-2", name: "Weekly digest",
                    prompt: "",
                    schedule: CronSchedule(kind: "cron", expr: "0 9 * * 1", display: "every monday at 09:00"),
                    scheduleDisplay: "every monday at 09:00",
                    enabled: false, state: "paused", deliver: "bot-chat:default",
                    pausedAt: "2026-09-01T09:00:00", pausedReason: "paused by user",
                    profile: "default", profileName: "default", isDefaultProfile: true),
                CronJobRecord(
                    id: "script-cron-3", name: "Nightly pin sweep",
                    prompt: "",
                    schedule: CronSchedule(kind: "cron", expr: "*/30 * * * *", display: "*/30 * * * *"),
                    scheduleDisplay: "*/30 * * * *",
                    enabled: true, state: "scheduled", noAgent: true, script: "fleet_pin.sh",
                    deliver: "local", nextRunAt: "2026-09-05T07:30:00",
                    profile: "default", profileName: "default", isDefaultProfile: true),
            ]
            runsByJob = [
                // One agent run for the briefing job; the script job has none
                // BY DESIGN (scheduler short-circuits before the session store).
                "script-cron-1": [
                    CronRunSession(
                        id: "cron_script-cron-1_1788596400", title: "Cron: Fleet morning briefing",
                        source: "cron", startedAt: 1_788_596_400, endedAt: 1_788_596_431,
                        lastActive: 1_788_596_431, messageCount: 8,
                        preview: "Summarize fleet activity since yesterday",
                        profile: "default", isActive: false, archived: false),
                ],
            ]
        }
    }

    /// Async-safe scoped lock helper (NSLock is unavailable in async
    /// contexts on this toolchain — same helper as ScriptedManagementSeam).
    private func unlocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func replacingState(
        _ record: CronJobRecord, enabled: Bool, state: String, nextRunAt: String?
    ) -> CronJobRecord {
        CronJobRecord(
            id: record.id, name: record.name, prompt: record.prompt,
            schedule: record.schedule, scheduleDisplay: record.scheduleDisplay,
            enabled: enabled, state: state,
            noAgent: record.noAgent, script: record.script, skills: record.skills,
            model: record.model, provider: record.provider, deliver: record.deliver,
            failureDeliver: record.failureDeliver,
            nextRunAt: nextRunAt, lastRunAt: record.lastRunAt, lastStatus: record.lastStatus,
            lastError: record.lastError, lastDeliveryError: record.lastDeliveryError,
            lastDeliveryUnverified: record.lastDeliveryUnverified, failureStreak: record.failureStreak,
            pausedAt: record.pausedAt, pausedReason: record.pausedReason,
            createdAt: record.createdAt, updatedAt: record.updatedAt,
            repeatTimes: record.repeatTimes, repeatCompleted: record.repeatCompleted,
            profile: record.profile, profileName: record.profileName,
            isDefaultProfile: record.isDefaultProfile, latestExecution: record.latestExecution)
    }

    // MARK: CronDashboardProviding

    func listJobs(profile: String?) async throws -> [CronJobRecord] {
        unlocked { jobs }
    }

    func job(id: String, profile: String?) async throws -> CronJobRecord {
        let found = unlocked { jobs.first { $0.id == id } }
        guard let found else { throw CronDashboardError.notFound }
        // Wire fidelity: detail reads carry NO ledger (only list reads attach
        // it) — the model composes it from the list snapshot.
        return found.withLatestExecution(nil)
    }

    func createJob(_ request: CronJobCreateRequest, profile: String?) async throws -> CronJobRecord {
        guard request.isValid else {
            throw CronDashboardError.invalidRequest("a job needs a name, a schedule, and a prompt")
        }
        let job = CronJobRecord(
            id: "script-cron-\(UUID().uuidString.prefix(6))",
            name: request.name, prompt: request.prompt,
            schedule: CronSchedule(kind: "cron", expr: request.schedule, display: request.schedule),
            scheduleDisplay: request.schedule,
            enabled: true, state: "scheduled",
            noAgent: request.noAgent, script: request.script,
            deliver: request.deliver.isEmpty ? "local" : request.deliver,
            nextRunAt: "2026-09-05T07:00:00",
            profile: profile ?? "default", profileName: profile ?? "default",
            isDefaultProfile: (profile ?? "default") == "default")
        return unlocked {
            jobs.append(job)
            return job
        }
    }

    func updateJob(id: String, patch: CronJobPatch, profile: String?) async throws -> CronJobRecord {
        let index = unlocked { jobs.firstIndex { $0.id == id } }
        guard let index else { throw CronDashboardError.notFound }
        return unlocked {
            let old = jobs[index]
            let name = patch.name ?? old.name
            let scheduleText = patch.schedule ?? old.scheduleDisplay
            let new = CronJobRecord(
                id: old.id, name: name,
                prompt: patch.prompt ?? old.prompt,
                schedule: CronSchedule(kind: "cron", expr: scheduleText, display: scheduleText),
                scheduleDisplay: scheduleText,
                enabled: old.enabled, state: old.state,
                noAgent: old.noAgent, script: old.script, skills: old.skills,
                model: old.model, provider: old.provider,
                deliver: patch.deliver ?? old.deliver,
                failureDeliver: old.failureDeliver,
                nextRunAt: old.nextRunAt, lastRunAt: old.lastRunAt, lastStatus: old.lastStatus,
                lastError: old.lastError, lastDeliveryError: old.lastDeliveryError,
                lastDeliveryUnverified: old.lastDeliveryUnverified, failureStreak: old.failureStreak,
                pausedAt: old.pausedAt, pausedReason: old.pausedReason,
                createdAt: old.createdAt, updatedAt: "2026-09-05T08:00:00",
                repeatTimes: old.repeatTimes, repeatCompleted: old.repeatCompleted,
                profile: old.profile, profileName: old.profileName,
                isDefaultProfile: old.isDefaultProfile, latestExecution: old.latestExecution)
            jobs[index] = new
            // Wire fidelity: PUT responses carry NO ledger.
            return new.withLatestExecution(nil)
        }
    }

    func pauseJob(id: String, profile: String?) async throws -> CronJobRecord {
        try await setEnabled(id: id, enabled: false)
    }

    func resumeJob(id: String, profile: String?) async throws -> CronJobRecord {
        try await setEnabled(id: id, enabled: true)
    }

    private func setEnabled(id: String, enabled: Bool) async throws -> CronJobRecord {
        let index = unlocked { jobs.firstIndex { $0.id == id } }
        guard let index else { throw CronDashboardError.notFound }
        return unlocked {
            let old = jobs[index]
            let new = replacingState(
                old, enabled: enabled,
                state: enabled ? "scheduled" : "paused",
                nextRunAt: enabled ? (old.nextRunAt ?? "2026-09-05T07:00:00") : old.nextRunAt)
            jobs[index] = new
            // Wire fidelity: pause/resume responses carry NO ledger.
            return new.withLatestExecution(nil)
        }
    }

    func triggerJob(id: String, profile: String?) async throws -> CronJobRecord {
        let index = unlocked { jobs.firstIndex { $0.id == id } }
        guard let index else { throw CronDashboardError.notFound }
        return unlocked {
            let old = jobs[index]
            let new = CronJobRecord(
                id: old.id, name: old.name, prompt: old.prompt,
                schedule: old.schedule, scheduleDisplay: old.scheduleDisplay,
                enabled: old.enabled, state: old.state,
                noAgent: old.noAgent, script: old.script, skills: old.skills,
                model: old.model, provider: old.provider, deliver: old.deliver,
                failureDeliver: old.failureDeliver,
                nextRunAt: old.nextRunAt, lastRunAt: "2026-09-05T08:05:00", lastStatus: "ok",
                lastError: nil, lastDeliveryError: nil, lastDeliveryUnverified: nil,
                failureStreak: 0, pausedAt: old.pausedAt, pausedReason: old.pausedReason,
                createdAt: old.createdAt, updatedAt: old.updatedAt,
                repeatTimes: old.repeatTimes,
                repeatCompleted: (old.repeatCompleted ?? 0) + 1,
                profile: old.profile, profileName: old.profileName,
                isDefaultProfile: old.isDefaultProfile,
                latestExecution: CronExecution(
                    id: "exec-\(old.id)-\(old.repeatCompleted ?? 0)", status: "completed",
                    source: "builtin", pid: 4242,
                    claimedAt: "2026-09-05T08:05:00", startedAt: "2026-09-05T08:05:00",
                    finishedAt: "2026-09-05T08:05:02", deliveryOutcome: "delivered"))
            jobs[index] = new
            // Wire fidelity: the trigger response is a ledger-less job refresh
            // (`_trigger_cron_job_sync`); the fresh ledger appears on the next
            // LIST read, which the pane performs right after triggering.
            return new.withLatestExecution(nil)
        }
    }

    func deleteJob(id: String, profile: String?) async throws {
        let exists = unlocked { jobs.contains { $0.id == id } }
        guard exists else { throw CronDashboardError.notFound }
        unlocked { jobs.removeAll { $0.id == id } }
        unlocked { runsByJob[id] = nil }
    }

    func runSessions(jobID: String, profile: String?, limit: Int) async throws -> [CronRunSession] {
        unlocked { runsByJob[jobID] ?? [] }
    }

    func deliveryTargets() async throws -> [CronDeliveryTarget] {
        [
            CronDeliveryTarget(id: "local", name: "Local (save only)", homeTargetSet: true),
            CronDeliveryTarget(id: "bot-chat:default", name: "Bot Chat (default)", homeTargetSet: true),
            CronDeliveryTarget(id: "telegram", name: "Telegram", homeTargetSet: false, homeEnvVar: "TELEGRAM_CHAT_ID"),
        ]
    }
}