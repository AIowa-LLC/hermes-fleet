import XCTest
import FleetCore
import FleetUI

/// TRUE BOTS MODE slice 3 (D13) — bot routines view model over a scripted
/// `GatewayManagementProviding` seam: list/pause/resume/remove/create with
/// `[bot:<slug>]` namespace + `bot-chat:<slug>` deliver, general-cron
/// isolation, and the honest run-now capability gate (4016 → unsupported,
/// never a facade).
@MainActor
final class BotRoutinesViewModelTests: XCTestCase {

    // MARK: - Scripted seam

    private final class ScriptedRoutines: GatewayManagementProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _jobs: [CronJob]
        private var _calls: [(action: String, jobID: String?, profile: String?)] = []
        private var _fireError: Error?
        /// Captured create drafts (name/schedule/prompt/deliver).
        private var _drafts: [CronJobDraft] = []

        init(jobs: [CronJob]) {
            _jobs = jobs
        }

        private func unlocked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var calls: [(action: String, jobID: String?, profile: String?)] {
            unlocked { _calls }
        }
        var drafts: [CronJobDraft] { unlocked { _drafts } }

        func setFireError(_ error: Error?) {
            unlocked { _fireError = error }
        }

        func listCronJobs(profile: String?) async throws -> [CronJob] {
            unlocked { _calls.append(("list", nil, profile)) }
            return unlocked { _jobs }
        }

        func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
            unlocked {
                _calls.append(("add", nil, profile))
                _drafts.append(draft)
            }
            let job = CronJob(
                jobID: "job-new",
                name: draft.name, schedule: draft.schedule,
                nextRunAt: "2026-09-08T07:00:00", isEnabled: true, state: "enabled",
                promptPreview: String(draft.prompt.prefix(40)),
                deliver: draft.deliver)
            return unlocked {
                _jobs.append(job)
                return job
            }
        }

        func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
            unlocked { _calls.append((enabled ? "resume" : "pause", jobID, profile)) }
            return unlocked {
                let index = _jobs.firstIndex { $0.jobID == jobID }!
                let old = _jobs[index]
                let updated = CronJob(
                    jobID: old.jobID, name: old.name, schedule: old.schedule,
                    nextRunAt: enabled ? "2026-09-08T07:00:00" : nil,
                    lastRunAt: old.lastRunAt, lastStatus: old.lastStatus,
                    isEnabled: enabled, state: enabled ? "enabled" : "paused",
                    promptPreview: old.promptPreview, deliver: old.deliver,
                    repeatDisplay: old.repeatDisplay,
                    lastFireError: old.lastFireError,
                    lastDeliveryError: old.lastDeliveryError,
                    pausedReason: old.pausedReason)
                _jobs[index] = updated
                return updated
            }
        }

        func deleteCronJob(_ jobID: String, profile: String?) async throws {
            unlocked {
                _calls.append(("remove", jobID, profile))
                _jobs.removeAll { $0.jobID == jobID }
            }
        }

        func fireCronJob(_ jobID: String, profile: String?) async throws {
            unlocked { _calls.append(("run", jobID, profile)) }
            let error = unlocked {
                let e = _fireError
                _fireError = nil
                return e
            }
            if let error { throw error }
        }

        func skillsCatalog(profile: String) async throws -> SkillsCatalog {
            SkillsCatalog(categories: [], enabledByName: [:])
        }

        func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
            enabled
        }
    }

    private static func fixtureJobs() -> [CronJob] {
        [
            CronJob(jobID: "g1", name: "Fleet morning briefing", schedule: "every day at 07:00"),
            CronJob(
                jobID: "r1", name: "[bot:researcher] Morning briefing",
                schedule: "every day at 07:00", nextRunAt: "2026-09-08T07:00:00",
                lastRunAt: "2026-09-07T07:00:02", lastStatus: "ok",
                isEnabled: true, state: "enabled", promptPreview: "Summarize overnight activity.",
                deliver: "bot-chat:researcher", repeatDisplay: "forever"),
            CronJob(
                jobID: "r2", name: "[bot:researcher] Weekly digest",
                schedule: "every monday at 09:00",
                isEnabled: false, state: "paused", pausedReason: "paused by user"),
            CronJob(jobID: "r3", name: "[bot:coder] Standup", schedule: "every day at 09:00"),
        ]
    }

    private static func researcherRoute() -> Route {
        Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "researcher"))
    }

    // MARK: - List: only this bot's namespaced routines

    func testStartListsOnlyThisBotsRoutinesPausedIncluded() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        XCTAssertEqual(model.routines.map(\.jobID), ["r1", "r2"],
                       "only [bot:researcher] jobs render — general and other-bots' jobs never leak in")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.routines.first?.routineName, "Morning briefing")
        XCTAssertEqual(model.routines.first?.failureDetail, nil)
        // The list call was scoped to the OWNING bot's profile store.
        XCTAssertEqual(seam.calls.first?.action, "list")
        XCTAssertEqual(seam.calls.first?.profile, "researcher")
    }

    func testPausedRoutineCarriesFailureAssociation() async {
        var jobs = Self.fixtureJobs()
        jobs.append(CronJob(
            jobID: "r4", name: "[bot:researcher] Broken recap",
            schedule: "every day at 21:00", lastStatus: "fire_failed",
            lastFireError: "provider auth missing",
            pausedReason: "auto-paused after failures"))
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: ScriptedRoutines(jobs: jobs))
        await model.start()

        let broken = model.routines.first { $0.jobID == "r4" }
        XCTAssertEqual(broken?.failureDetail, "provider auth missing",
                       "last_fire_error is the most specific failure field")
    }

    // MARK: - Pause / resume

    func testPauseTogglesWireAndReloadsFromServerTruth() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        let r1 = model.routines[0]
        await model.setRoutine(r1, enabled: false)

        // The pause call went out with the job id + profile scope (the
        // trailing call is the post-toggle reload's list).
        let pause = seam.calls.last { $0.action == "pause" }
        XCTAssertEqual(pause?.jobID, "r1")
        XCTAssertEqual(pause?.profile, "researcher")
        // The reloaded row reflects the server's paused truth.
        XCTAssertFalse(model.routines.first { $0.jobID == "r1" }!.isEnabled)
        XCTAssertNil(model.routines.first { $0.jobID == "r1" }!.nextRunAt)
        XCTAssertEqual(model.toggled, 1)
    }

    // MARK: - Remove: two-step destructive confirm

    func testRemoveRequiresConfirmationAndDeletesOnConfirm() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        let r2 = model.routines[1]
        model.requestRemoval(of: r2)
        XCTAssertEqual(model.pendingRemoval?.jobID, "r2")
        // Nothing hit the wire before the confirmation.
        XCTAssertFalse(seam.calls.contains { $0.action == "remove" })

        await model.confirmRemoval()
        XCTAssertNil(model.pendingRemoval)
        XCTAssertEqual(seam.calls.last?.action, "remove")
        XCTAssertEqual(seam.calls.last?.jobID, "r2")
        XCTAssertEqual(model.routines.map(\.jobID), ["r1"],
                       "the removed routine is gone from the list")
    }

    func testCancelRemovalIssuesNoWireCall() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        model.requestRemoval(of: model.routines[0])
        model.cancelRemoval()
        XCTAssertNil(model.pendingRemoval)
        XCTAssertFalse(seam.calls.contains { $0.action == "remove" })
        XCTAssertEqual(model.routines.count, 2)
    }

    // MARK: - Create: namespace + deliver target

    func testCreateStampsNamespaceAndBotChatDeliver() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        let ok = await model.createRoutine(
            label: "Evening recap", schedule: "every day at 21:00",
            prompt: "Recap the day.")
        XCTAssertTrue(ok)

        XCTAssertEqual(seam.drafts.count, 1)
        XCTAssertEqual(seam.drafts[0].name, "[bot:researcher] Evening recap",
                       "the user-facing label is namespaced — the namespace is never user-typed")
        XCTAssertEqual(seam.drafts[0].deliver, "bot-chat:researcher",
                       "deliver defaults to the bot's canonical Bot Chat")
        XCTAssertEqual(seam.drafts[0].schedule, "every day at 21:00")
        XCTAssertEqual(seam.calls.last?.profile, "researcher")

        // The created row parsed back as this bot's routine.
        XCTAssertEqual(model.routines.last?.routineName, "Evening recap")
        XCTAssertNil(model.formError)
    }

    func testCreateRejectsEmptyFieldsClientSide() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        let ok = await model.createRoutine(label: "  ", schedule: "every day at 07:00", prompt: "x")
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.formError)
        XCTAssertTrue(seam.drafts.isEmpty, "no wire call for an invalid draft")
    }

    // MARK: - Run-now honest gate

    func testRunNowMaps4016ToHonestUnsupportedState() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        seam.setFireError(GatewayManagementError.unsupportedAction("unknown cron action: run"))
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        await model.runNow(model.routines[0])

        XCTAssertTrue(model.runNowUnsupported,
                      "a typed unsupportedAction answer flips the honest gate on")
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.errorMessage, "unsupported is an explanation, not an error")
        // The attempt DID go out with the correct wire spelling.
        let run = seam.calls.last { $0.action == "run" }
        XCTAssertEqual(run?.jobID, "r1")
        XCTAssertEqual(run?.profile, "researcher")
    }

    func testRunNowUnsupportedIsStickyForTheSession() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        seam.setFireError(GatewayManagementError.unsupportedAction("unknown cron action: run"))
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        await model.runNow(model.routines[0])
        // Second attempt: no further wire calls against the wall.
        let callsAfterFirst = seam.calls.count
        seam.setFireError(nil)
        await model.runNow(model.routines[0])
        XCTAssertEqual(seam.calls.count, callsAfterFirst,
                       "once unsupported is known, no retry loop fires")
    }

    func testRunNowSuccessSurfacesNotice() async {
        let seam = ScriptedRoutines(jobs: Self.fixtureJobs())
        let model = BotRoutinesViewModel(route: Self.researcherRoute(), management: seam)
        await model.start()

        await model.runNow(model.routines[0])
        XCTAssertFalse(model.runNowUnsupported)
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Capability: unavailable seam fails honestly

    func testUnavailableSeamSurfacesTypedErrorNoFallback() async {
        let model = BotRoutinesViewModel(
            route: Self.researcherRoute(),
            management: UnsupportedGatewayManagement())
        await model.start()

        XCTAssertTrue(model.routines.isEmpty)
        XCTAssertNotNil(model.errorMessage,
                        "a gateway without the management surface fails closed — no fabricated rows")
        XCTAssertEqual(model.errorMessage, "gateway not configured")
    }

    // MARK: - Deliver target helper

    func testBotChatDeliverTargetShape() async {
        XCTAssertEqual(
            BotRoutinesViewModel.botChatDeliverTarget(for: "researcher"),
            "bot-chat:researcher")
    }
}
