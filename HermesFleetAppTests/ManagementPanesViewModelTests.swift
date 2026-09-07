import XCTest
import FleetCore
import FleetPersistence
import FleetUI
@testable import HermesFleetApp

/// R9-T5/T6 — management view model: cron list/toggle/fire-now/delete and
/// skills catalog/toggle over the scripted `GatewayManagementProviding`
/// seam, with per-gateway + per-profile scoping.
@MainActor
final class ManagementPanesViewModelTests: XCTestCase {

    // MARK: - Scripted seam

    private final class ScriptedManagement: GatewayManagementProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _jobs: [CronJob]
        private var _calls: [(String, String?)] = []
        private var _disabledSkills: Set<String>
        private var _catalogCategories: [(category: String, skills: [String])]
        private var _fireNowError: Error?
        private var _failNext: Error?

        init(
            jobs: [CronJob] = [
                CronJob(
                    jobID: "job-1", name: "Morning briefing", schedule: "every day at 07:00",
                    nextRunAt: "2026-09-05T07:00:00", lastRunAt: "2026-09-04T07:00:03",
                    lastStatus: "ok", isEnabled: true, state: "enabled",
                    promptPreview: "Summarize fleet activity..."),
                CronJob(
                    jobID: "job-2", name: "Weekly digest", schedule: "every monday at 09:00",
                    nextRunAt: nil, lastRunAt: nil, lastStatus: nil,
                    isEnabled: false, state: "paused", promptPreview: nil),
            ],
            disabledSkills: Set<String> = ["systematic-debugging"],
            catalogCategories: [(category: String, skills: [String])] = [
                ("dev", ["codex", "systematic-debugging", "test-driven-development"]),
                ("github", ["github-code-review", "github-pr-workflow"]),
            ]
        ) {
            _jobs = jobs
            _disabledSkills = disabledSkills
            _catalogCategories = catalogCategories
        }

        /// Async-safe scoped lock helper (NSLock is unavailable in async
        /// contexts on this toolchain).
        private func unlocked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var calls: [(String, String?)] {
            unlocked { _calls }
        }
        var jobs: [CronJob] {
            unlocked { _jobs }
        }

        func setFireNowError(_ error: Error?) {
            unlocked { _fireNowError = error }
        }
        func failNext(_ error: Error) {
            unlocked { _failNext = error }
        }

        private func record(_ action: String, _ profile: String?) {
            unlocked { _calls.append((action, profile)) }
        }

        private func takeFailNext() -> Error? {
            unlocked {
                let e = _failNext
                _failNext = nil
                return e
            }
        }

        func listCronJobs(profile: String?) async throws -> [CronJob] {
            record("list", profile)
            if let e = takeFailNext() { throw e }
            return jobs
        }

        func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
            record("add", profile)
            if let e = takeFailNext() { throw e }
            let job = CronJob(
                jobID: "job-new", name: draft.name, schedule: draft.schedule,
                nextRunAt: "2026-09-04T22:00:00", isEnabled: true, state: "enabled",
                promptPreview: String(draft.prompt.prefix(40)))
            return unlocked {
                _jobs.append(job)
                return job
            }
        }

        func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
            record(enabled ? "resume" : "pause", profile)
            if let e = takeFailNext() { throw e }
            let index = unlocked { _jobs.firstIndex { $0.jobID == jobID } }
            guard let index else {
                throw GatewayManagementError.rpcFailed("no such job")
            }
            return unlocked {
                let old = _jobs[index]
                let updated = CronJob(
                    jobID: old.jobID, name: old.name, schedule: old.schedule,
                    nextRunAt: old.nextRunAt, lastRunAt: old.lastRunAt,
                    lastStatus: old.lastStatus, isEnabled: enabled,
                    state: enabled ? "enabled" : "paused", promptPreview: old.promptPreview)
                _jobs[index] = updated
                return updated
            }
        }

        func deleteCronJob(_ jobID: String, profile: String?) async throws {
            record("remove", profile)
            if let e = takeFailNext() { throw e }
            unlocked { _jobs.removeAll { $0.jobID == jobID } }
        }

        func fireCronJob(_ jobID: String, profile: String?) async throws {
            record("run", profile)
            let fireError = unlocked { _fireNowError }
            if let fireError { throw fireError }
            if let e = takeFailNext() { throw e }
        }

        func skillsCatalog(profile: String) async throws -> SkillsCatalog {
            record("skills.list", profile)
            if let e = takeFailNext() { throw e }
            let (categories, disabled) = unlocked { (_catalogCategories, _disabledSkills) }
            // Mirrors the live 0.21.0 server: `skills.manage list` EXCLUDES
            // disabled skills (tools/skills_tool.py:773) with no include flag
            // on the WS handler (methods_tools.py:1916-1919), while
            // `profiles.describe` reports the full installed set with
            // enablement (methods_profiles.py:625-640).
            let visibleCategories = categories
                .map { (category: $0.category, skills: $0.skills.filter { !disabled.contains($0.lowercased()) }) }
                .filter { !$0.skills.isEmpty }
            let described = categories.flatMap { $0.skills }
            let enabledByName = Dictionary(
                uniqueKeysWithValues: described.map { name in
                    (name.lowercased(), !disabled.contains(name.lowercased()))
                })
            return SkillsCatalog(
                unionOf: visibleCategories, describedSkills: enabledByName)
        }

        func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
            record("skill.toggle", profile)
            if let e = takeFailNext() { throw e }
            return unlocked {
                if enabled {
                    _disabledSkills.remove(name.lowercased())
                } else {
                    _disabledSkills.insert(name.lowercased())
                }
                return enabled
            }
        }
    }

    // MARK: - Cron pane

    func testLoadListsJobsScopedToProfile() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)

        await vm.start(profile: "default")

        XCTAssertEqual(vm.cronJobs.map(\.jobID), ["job-1", "job-2"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(seam.calls.first?.0, "list")
        XCTAssertEqual(seam.calls.first?.1, "default",
                       "jobs belong to the gateway's profile — the scope rides every call")
    }

    func testTogglePauseDisablesJobAndRecordShowsOutcome() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        await vm.setCronJob("job-1", enabled: false, profile: "default")

        XCTAssertEqual(vm.cronJobs.first { $0.jobID == "job-1" }?.isEnabled, false)
        XCTAssertEqual(vm.jobsToggled, 1, "the row's toggle feedback counter advances")
        XCTAssertTrue(seam.calls.contains { $0.0 == "pause" && $0.1 == "default" })
    }

    func testFireNowSurfacesUnsupportedActionAsNotice() async {
        let seam = ScriptedManagement()
        seam.setFireNowError(GatewayManagementError.unsupportedAction("unknown cron action: run"))
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        await vm.fireCronJob("job-1", profile: "default")

        // The honest 0.21.0 state: fire-now is surfaced as an unsupported
        // NOTICE with the job intact (not an error banner over the pane).
        XCTAssertNil(vm.errorMessage, "unsupported fire-now must not read as a pane failure")
        XCTAssertNotNil(vm.notice)
        XCTAssertEqual(vm.cronJobs.count, 2, "the job is untouched")
    }

    func testFireNowSuccessSetsNoticeAndRefreshes() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        await vm.fireCronJob("job-1", profile: "default")

        XCTAssertEqual(vm.notice, "Run requested — the job is firing now.")
        XCTAssertNil(vm.errorMessage)
    }

    func testDeleteRemovesJob() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        await vm.deleteCronJob("job-1", profile: "default")

        XCTAssertEqual(vm.cronJobs.map(\.jobID), ["job-2"])
        XCTAssertTrue(seam.calls.contains { $0.0 == "remove" && $0.1 == "default" })
    }

    func testCreateAppendsJobFromDraft() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        await vm.createCronJob(
            CronJobDraft(name: "Evening recap", schedule: "every day at 21:00", prompt: "Recap the day."),
            profile: "default")

        XCTAssertEqual(vm.cronJobs.map(\.name).last, "Evening recap")
        XCTAssertNil(vm.formError)
    }

    func testCreateFailureKeepsFormErrorForSheet() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")
        // Fail ONLY the create (set after the load succeeded).
        seam.failNext(GatewayManagementError.rpcFailed("bad schedule"))

        let ok = await vm.createCronJob(
            CronJobDraft(name: "X", schedule: "garbage", prompt: "y"),
            profile: "default")

        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.formError)
        XCTAssertEqual(vm.cronJobs.count, 2, "no phantom row on failure")
    }

    func testLoadFailureSurfacesError() async {
        let seam = ScriptedManagement()
        seam.failNext(GatewayManagementError.rpcFailed("gateway not connected"))
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)

        await vm.start(profile: "default")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.cronJobs.isEmpty)
    }

    // MARK: - Skills pane

    func testSkillsLoadRowsWithEnablement() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)

        await vm.start(profile: "default")

        XCTAssertEqual(vm.skillsRows.count, 5)
        XCTAssertEqual(vm.skillsRows.first?.name, "codex")
        XCTAssertEqual(vm.skillsRows.first?.isEnabled, true)
        let debugging = vm.skillsRows.first { $0.name == "systematic-debugging" }
        XCTAssertEqual(debugging?.isEnabled, false)
        XCTAssertEqual(vm.categoryGroups.first?.category, "dev")
        XCTAssertEqual(vm.categoryGroups.first?.rows.count, 2,
                       "the list pass filters disabled skills out of their categories")
        // The disabled describe-only skill renders under the fallback group
        // with its toggle — never vanishes (review round 1 union).
        let fallback = vm.categoryGroups.first { $0.category == SkillsCatalog.fallbackCategory }
        XCTAssertEqual(fallback?.rows.map(\.name), ["systematic-debugging"])
        XCTAssertEqual(fallback?.rows.first?.isEnabled, false)
    }

    func testSkillToggleRoundTrips() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        await vm.setSkill("systematic-debugging", enabled: true, profile: "default")

        XCTAssertEqual(vm.skillsRows.first { $0.name == "systematic-debugging" }?.isEnabled, true)
        XCTAssertTrue(seam.calls.contains { $0.0 == "skill.toggle" && $0.1 == "default" })
    }

    /// Review round-1 finding: on a live 0.21.0 gateway, disabling a skill
    /// removes it from `skills.manage list` (skills_tool.py:773) while
    /// `profiles.describe` still reports it enabled:false. A reload must
    /// keep the row (with its toggle) — disable must not be a one-way door.
    func testDisabledSkillSurvivesCatalogReload() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        // Disable a skill, then RELOAD the catalog the way a
        // pull-to-refresh does — the seam now mirrors the server's
        // list-side filtering.
        await vm.setSkill("codex", enabled: false, profile: "default")
        await vm.refresh(profile: "default")

        XCTAssertEqual(
            vm.skillsRows.count, 5,
            "every described skill keeps a row even when the list pass drops it")
        let codex = vm.skillsRows.first { $0.name == "codex" }
        XCTAssertEqual(codex?.isEnabled, false, "describe-only skill surfaces disabled")
        XCTAssertTrue(
            vm.categoryGroups.contains { $0.rows.contains { $0.name == "codex" } },
            "describe-only skill renders in a group with its toggle")
    }

    func testInFlightToggleGuardPreventsDoubleFire() async {
        let seam = ScriptedManagement()
        let vm = ManagementPanesViewModel(gatewayID: .init(rawValue: "workstation"), management: seam)
        await vm.start(profile: "default")

        // A pending toggle for the same skill must not start a second wire
        // call (optimistic UI guard).
        vm.markSkillPending("codex", pending: true)
        await vm.setSkill("codex", enabled: false, profile: "default")
        XCTAssertFalse(
            seam.calls.contains { $0.0 == "skill.toggle" },
            "a toggle while the row is pending must be dropped, not double-fired")
    }
}
