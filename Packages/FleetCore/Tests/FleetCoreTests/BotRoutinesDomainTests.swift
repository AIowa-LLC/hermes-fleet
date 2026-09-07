import XCTest
@testable import FleetCore

/// TRUE BOTS MODE slice 3 (D13) — the `[bot:<name>] <routine>` namespace
/// domain: parse/encode round-trips, strict fail-closed parsing, ownership
/// association, and the general-cron isolation rule (bot routines never
/// hijack the general cron list).
final class BotRoutinesDomainTests: XCTestCase {

    // MARK: namespace encode/parse round-trip

    func testJobNameRoundTripsThroughParse() {
        let name = BotRoutineNamespace.jobName(owner: "researcher", routine: "Morning briefing")
        XCTAssertEqual(name, "[bot:researcher] Morning briefing")
        let parsed = BotRoutineNamespace.parse(name)
        XCTAssertEqual(parsed?.owner, "researcher")
        XCTAssertEqual(parsed?.routine, "Morning briefing")
    }

    func testParseAcceptsOwnerCaseDifferenceForLookup() {
        // Stored slug display case may differ; ownership compare is
        // case-insensitive (upstream normalize_profile_name lowercases).
        XCTAssertTrue(BotRoutineNamespace.isBotRoutine(
            name: "[bot:Researcher] Daily digest", owner: "researcher"))
        XCTAssertTrue(BotRoutineNamespace.isBotRoutine(
            name: "[bot:researcher] Daily digest", owner: "RESEARCHER"))
    }

    // MARK: strict fail-closed parsing

    func testMalformedPrefixesAreNeverRoutines() {
        XCTAssertNil(BotRoutineNamespace.parse("Morning briefing"))
        XCTAssertNil(BotRoutineNamespace.parse("bot:researcher] briefing"))
        XCTAssertNil(BotRoutineNamespace.parse("[bot:] briefing"), "empty owner")
        XCTAssertNil(BotRoutineNamespace.parse("[bot:researcher]"), "empty routine label")
        XCTAssertNil(BotRoutineNamespace.parse("[bot:researcher]    "), "whitespace-only routine")
        XCTAssertNil(BotRoutineNamespace.parse("[bot:two words] briefing"), "owner with a space is not a slug")
        XCTAssertNil(BotRoutineNamespace.parse("[bot:researcher"), "unclosed bracket")
    }

    func testIsBotRoutineNameClassification() {
        XCTAssertTrue(BotRoutineNamespace.isBotRoutine(name: "[bot:default] Evening recap"))
        XCTAssertFalse(BotRoutineNamespace.isBotRoutine(name: "Evening recap"))
        XCTAssertFalse(BotRoutineNamespace.isBotRoutine(name: "[bot:] Evening recap"))
        XCTAssertFalse(BotRoutineNamespace.isBotRoutine(name: "[bot:x"), "unclosed")
    }

    // MARK: ownership association

    func testRoutineInitAdoptsOnlyNamespacedJobsOfOwner() {
        let owned = CronJob(
            jobID: "job-1", name: "[bot:researcher] Morning briefing",
            schedule: "every day at 07:00", nextRunAt: "2026-09-08T07:00:00",
            lastRunAt: "2026-09-07T07:00:02", lastStatus: "ok",
            isEnabled: true, state: "enabled",
            promptPreview: "Summarize overnight fleet activity.",
            deliver: "bot-chat:researcher", repeatDisplay: "forever")
        let someoneElses = CronJob(
            jobID: "job-2", name: "[bot:coder] Standup notes",
            schedule: "every day at 09:00")
        let general = CronJob(
            jobID: "job-3", name: "Fleet morning briefing",
            schedule: "every day at 07:00")

        let routine = BotRoutine(job: owned, owner: "researcher")
        XCTAssertNotNil(routine)
        XCTAssertEqual(routine?.routineName, "Morning briefing")
        XCTAssertEqual(routine?.ownerSlug, "researcher")
        XCTAssertEqual(routine?.jobID, "job-1")
        XCTAssertEqual(routine?.deliver, "bot-chat:researcher")

        XCTAssertNil(BotRoutine(job: someoneElses, owner: "researcher"),
                     "another bot's namespaced job is never adopted")
        XCTAssertNil(BotRoutine(job: general, owner: "researcher"),
                     "a general cron job is never adopted as a routine")
    }

    func testFailureDetailPrefersMostSpecificField() {
        let fire = CronJob(
            jobID: "j", name: "[bot:a] x", schedule: "s",
            lastFireError: "agent build failed", lastDeliveryError: "telegram 429",
            pausedReason: "manual")
        XCTAssertEqual(BotRoutine(job: fire, owner: "a")?.failureDetail, "agent build failed")

        let deliveryOnly = CronJob(
            jobID: "j", name: "[bot:a] x", schedule: "s",
            lastDeliveryError: "telegram 429")
        XCTAssertEqual(BotRoutine(job: deliveryOnly, owner: "a")?.failureDetail, "telegram 429")

        let pausedOnly = CronJob(
            jobID: "j", name: "[bot:a] x", schedule: "s", pausedReason: "manual pause")
        XCTAssertEqual(BotRoutine(job: pausedOnly, owner: "a")?.failureDetail, "manual pause")

        let healthy = CronJob(jobID: "j", name: "[bot:a] x", schedule: "s")
        XCTAssertNil(BotRoutine(job: healthy, owner: "a")?.failureDetail)
    }

    // MARK: filter isolation (general cron preserved)

    func testRoutinesFilterIsolatesBotRoutinesFromGeneralCron() {
        let jobs = [
            CronJob(jobID: "g1", name: "Fleet morning briefing", schedule: "every day at 07:00"),
            CronJob(jobID: "r1", name: "[bot:researcher] Morning briefing", schedule: "every day at 07:00"),
            CronJob(jobID: "r2", name: "[bot:coder] Standup notes", schedule: "every day at 09:00"),
            CronJob(jobID: "bad", name: "[bot:broken no-close", schedule: "every day at 10:00"),
        ]
        let researcherRoutines = BotRoutineFilter.routines(in: jobs, owner: "researcher")
        XCTAssertEqual(researcherRoutines.map(\.jobID), ["r1"])

        let general = BotRoutineFilter.generalCronJobs(in: jobs)
        XCTAssertEqual(
            general.map(\.jobID), ["g1", "bad"],
            "malformed namespaced names are NOT routines — they stay general rows")
    }

    func testBotRoutineExposesRunNowCapabilityHonesty() {
        // The ws surface does not expose run (4016 upstream); the model
        // carries no fabricated run state — capability comes from the
        // gateway's answer, surfaced as an honest gate.
        let routine = BotRoutine(
            job: CronJob(jobID: "j", name: "[bot:a] x", schedule: "s"),
            owner: "a")
        XCTAssertEqual(routine?.jobID, "j")
        // No run-now fabrication API exists on the model: compile-time
        // property; nothing to assert beyond absence, covered by review.
    }
}
