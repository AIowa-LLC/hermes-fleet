import Foundation
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

#if DEBUG && targetEnvironment(simulator)

/// Scripted fleet simulator — DEBUG SIMULATOR builds ONLY (P0-5: a Debug
/// build on a physical device is a live-dogfood lane and must never contain
/// the fake fleet — see FleetServiceGraph.makeDefaultEnvironment).
///
/// U1 acceptance requires the navigation skeleton to be walkable in the
/// simulator: Gateways → Bots → Sessions → Conversation. Without a live Hermes
/// gateway wired with credentials, the real transport would classify every
/// gateway offline and the shell would show empty states end-to-end. This
/// simulator drives the SAME observable `AppEnvironment` runtime and the SAME
/// FleetCore seams with scripted services that return deterministic,
/// in-memory fleet data — so the whole cockpit flow is navigable on a booted
/// simulator. Release builds use the real production graph
/// (`FleetServiceGraph.makeProductionEnvironment`).
extension FleetServiceGraph {

    /// P2-5 UI-test knob: `HERMES_FLEET_ZERO_BOTS=1` makes EVERY scripted
    /// gateway report a healthy roster with ZERO bots, so the all-healthy
    /// all-empty roster state is reachable in a deterministic UI test.
    nonisolated static var zeroBotsEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_ZERO_BOTS"] == "1"
    }

    /// P2-6 UI-test knob: `HERMES_FLEET_SAVE_FAIL=1` makes the scripted
    /// registry's save path (add/update/saveCredential) throw, so the form's
    /// save-failure retry UX is reachable in a deterministic UI test.
    nonisolated static var saveFailEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_SAVE_FAIL"] == "1"
    }

    static func makeSimulatorEnvironment() -> AppEnvironment {
        // Scripted registry: in-memory credential store (no Keychain writes).
        let credentials = InMemoryCredentialStore()
        let baseRegistry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            }
        )
        // P2-6: when the save-fail knob is set, wrap the registry so the
        // add/edit save path throws (the UI test then verifies the form keeps
        // the sheet open, preserves non-secret fields, and surfaces the error).
        let registry: any GatewayRegistryManaging = if FleetServiceGraph.saveFailEnabled {
            FailingSaveRegistry(inner: baseRegistry)
        } else {
            baseRegistry
        }
        // Scripted union roster: FleetRosterService over scripted per-gateway
        // sessions (real M8 aggregation, scripted transport + roster RPCs).
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                ScriptedRosterSession(gatewayID: gateway.id)
            }
        )
        // Scripted session.list read path for Bot detail.
        let sessionList: any SessionListProviding = ScriptedSessionListService()
        // In-memory cache (scripted; no file-backed store in the simulator).
        // Doubles as the health-stats store: scripted connections do not emit
        // transport health events, so the dashboard shows live scripted state
        // with "no data yet" stats — honest for the DEBUG walkthrough.
        let cacheStore = try! SwiftDataCacheStore.makeInMemory()
        let cache: any CacheStoring = cacheStore
        let health = GatewayHealthStatsAccumulator(store: cacheStore)

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            },
            conversationFactory: { gateway, _ in
                ScriptedConversationSession(gatewayID: gateway.id)
            },
            kanbanWatcherFactory: { _ in
                ScriptedKanbanWatcher()
            },
            managementSeamFactory: { gateway in
                ScriptedManagementSeam(gatewayID: gateway.id)
            },
            learningSeamFactory: { gateway in
                ScriptedLearningSeam(gatewayID: gateway.id)
            },
            learningSnapshotStore: cacheStore,
            projectsSeamFactory: { gateway in
                ScriptedProjectsSeam(gatewayID: gateway.id)
            },
            projectsSnapshotStore: cacheStore,
            botModeChatFactory: { gateway in
                ScriptedBotModeChatSeam(gatewayID: gateway.id)
            },
            botProfileFactory: { gateway in
                ScriptedBotProfileSeam(gatewayID: gateway.id)
            },
            roomSourceFactory: { gateway in
                ScriptedRoomSource(gatewayID: gateway.id)
            },
            health: health,
            seedRegistrations: FleetServiceGraph.zeroGatewaysEnabled ? [] : ScriptedFleet.registrations,
            // R10-T4: scripted voice seam (env-knobbed) so the mic button,
            // authorization gate and transcript review are walkable
            // deterministically in the simulator + UI tests — no live speech.
            voiceEngineFactory: { ScriptedVoiceEngine.shared }
        )
    }
}

/// R10-T4 — scripted voice engine (DEBUG simulator only), env-knobbed:
/// - `HERMES_FLEET_VOICE_DENIED=1`: authorization reports denied (the honest
///   gate UI renders, no capture ever starts).
/// - `HERMES_FLEET_VOICE_TRANSCRIPT=1`: an authorized mic tap returns a fixed
///   FINAL transcript after a short delay (lands in the review chip).
/// - default: authorized, no transcript (listening state renders until the
///   tap-to-stop, which returns nil).
final class ScriptedVoiceEngine: VoiceTranscribing, @unchecked Sendable {
    static let shared = ScriptedVoiceEngine()

    private let lock = NSLock()
    private var _listening = false
    private var _stopRequested = false
    private var _spoken: [String] = []

    private var denied: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_VOICE_DENIED"] == "1"
    }
    private var scriptedTranscript: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_VOICE_TRANSCRIPT"] == "1"
    }

    // Sync lock helpers (NSLock is unavailable from async contexts).
    private func tryBeginListening() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _listening { return false }
        _listening = true
        _stopRequested = false
        return true
    }
    private func endListening() {
        lock.lock(); defer { lock.unlock() }
        _listening = false
    }
    private var stopRequestedFlag: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopRequested
    }
    private func requestStop() {
        lock.lock(); defer { lock.unlock() }
        _stopRequested = true
    }
    private func recordSpoken(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _spoken.append(text)
    }

    func authorizationStatus() async -> VoiceAuthorization { denied ? .denied : .authorized }
    func requestAuthorization() async -> VoiceAuthorization { denied ? .denied : .authorized }

    func transcribe() async throws -> VoiceTranscript? {
        guard tryBeginListening() else { throw VoiceError.alreadyListening }
        defer { endListening() }
        if scriptedTranscript {
            try? await Task.sleep(for: .milliseconds(400))
            return VoiceTranscript(text: "Scripted voice transcript for review", isFinal: true)
        }
        // Default: listen until the user taps stop (an honest "nothing
        // recognized" nil — no fabricated transcript).
        while !stopRequestedFlag {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func stopTranscribing() async {
        requestStop()
    }

    func speak(text: String) async throws {
        recordSpoken(text)
    }
    func stopSpeaking() async {}
    var isSpeaking: Bool { false }

    var spokenTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _spoken
    }
}

/// t_3b321b7b — scripted kanban board watcher (DEBUG simulator only): a
/// small static board with a self-updating event stream so the read-only
/// board view is walkable without a live gateway. Presentation data only.
/// t_624b81cd: also scripts the board LIST + client-side pinning so the
/// board selector is walkable deterministically (two boards, "R10
/// Maintenance" active).
private final class ScriptedKanbanWatcher: KanbanBoardWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
    private var pinned: String?
    /// UI-test knob: `HERMES_FLEET_KANBAN_LIVE_UPDATES=1` enables the scripted
    /// live-update ticker (default off — deterministic walkthroughs).
    private let liveUpdatesEnabled =
        ProcessInfo.processInfo.environment["HERMES_FLEET_KANBAN_LIVE_UPDATES"] == "1"

    private static let scriptedBoards = KanbanBoardList(
        boards: [
            KanbanBoardSummary(
                slug: "hermes-fleet-r10", name: "R10 Maintenance",
                isCurrent: true, total: 5),
            KanbanBoardSummary(
                slug: "side-quests", name: "Side Quests",
                isCurrent: false, total: 2),
        ],
        current: "hermes-fleet-r10")

    func fetchBoards() async throws -> KanbanBoardList {
        Self.scriptedBoards
    }

    func pinBoard(_ slug: String?) async {
        unlocked { pinned = slug }
    }

    func snapshot() async throws -> KanbanBoardSnapshot {
        let board: String? = unlocked { pinned }
        // Side Quests (the non-active scripted board) gets a distinct,
        // smaller snapshot so switching visibly changes the board content.
        if board == "side-quests" {
            return KanbanBoardSnapshot(
                columns: ["todo", "done"],
                cardsByColumn: [
                    "todo": [
                        KanbanCard(
                            id: "t_side01", title: "Scripted: side quest one",
                            status: "todo", assignee: "apple-dev",
                            priority: 1, createdAt: 1_780_003_600, latestSummary: nil),
                    ],
                    "done": [
                        KanbanCard(
                            id: "t_side02", title: "Scripted: side quest two",
                            status: "done", assignee: "apple-design",
                            priority: 1, createdAt: 1_779_996_400, latestSummary: nil),
                    ],
                ],
                latestEventID: 2,
                now: 1_780_014_400
            )
        }
        return KanbanBoardSnapshot(
            columns: ["triage", "todo", "ready", "running", "blocked", "review", "done"],
            cardsByColumn: [
                "todo": [
                    KanbanCard(id: "t_script01", title: "Scripted: port kanban stream client", status: "todo", assignee: "apple-dev", priority: 2, createdAt: 1_780_000_000, latestSummary: "Event-stream client pattern ported from the dashboard plugin contract."),
                    KanbanCard(id: "t_script02", title: "Scripted: read-only board view", status: "todo", assignee: "apple-design", priority: 1, createdAt: 1_780_003_600, latestSummary: nil)
                ],
                "running": [
                    KanbanCard(id: "t_script03", title: "Scripted: live reconnect coverage", status: "running", assignee: "apple-qa", priority: 3, createdAt: 1_780_007_200, latestSummary: "Reconnect resumes from the cursor — no events lost across the gap.")
                ],
                "review": [
                    KanbanCard(id: "t_script04", title: "Scripted: design review pass", status: "review", assignee: "apple-design", priority: 2, createdAt: 1_780_010_800, latestSummary: "Gold Fleet tokens applied; columns as horizontal lanes.")
                ],
                "done": [
                    KanbanCard(id: "t_script05", title: "Scripted: domain models", status: "done", assignee: "apple-dev", priority: 1, createdAt: 1_779_996_400, latestSummary: nil)
                ]
            ],
            latestEventID: 41,
            now: 1_780_014_400
        )
    }

    func changeEvents() async -> AsyncStream<KanbanEventBatch> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
            if liveUpdatesEnabled {
                // Ticker: one scripted event every 3s (capped ids so the
                // activity strip stays small).
                Task.detached { [weak self] in
                    var n = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, !Task.isCancelled else { return }
                        let batch = KanbanEventBatch(
                            events: [KanbanChangeEvent(
                                id: 100 + n, taskID: n % 2 == 0 ? "t_script03" : "t_script01",
                                kind: "heartbeat", createdAt: nil)],
                            cursor: 100 + n)
                        n += 1
                        let targets = self.unlocked { Array(self.continuations.values) }
                        for target in targets { target.yield(batch) }
                    }
                }
            }
        }
    }

    func stop() async {
        let targets = unlocked { () -> [AsyncStream<KanbanEventBatch>.Continuation] in
            let targets = Array(continuations.values)
            continuations.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }

    /// Async-safe scoped lock helper (NSLock is unavailable in async
    /// contexts on this toolchain).
    private func unlocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Scripted read-only `session.list` for Bot detail (DEBUG only).
/// Returns the scripted fleet's sessions for a route; never mutates.
private struct ScriptedSessionListService: SessionListProviding {
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        ScriptedFleet.sessions(on: route)
    }
}

/// True Bots Mode: scripted canonical-chat seam (DEBUG simulator only).
/// Deterministic fixture: one canonical "Bot Chat" row per profile
/// (id "botchat-<profile>"), env knob HERMES_FLEET_BOT_CHAT_FAIL forces
/// lookup failures so the fail-closed UI path is walkable.
final class ScriptedBotModeChatSeam: BotModeChatProviding, @unchecked Sendable {
    private let gatewayID: GatewayID
    private var created = Set<String>()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup {
        if FleetServiceGraph.botChatLookupFails {
            throw RosterError.rpcFailed("fixture lookup failure")
        }
        // The default profile already has one; other profiles return empty
        // first (confirmed miss → creation path) unless previously created.
        if profile != "default" && !created.contains(profile) {
            return CanonicalLookup(rows: [])
        }
        return CanonicalLookup(rows: [
            CanonicalLookupRow(
                id: "botchat-\(profile)",
                resolvedID: nil,
                title: BotModeContract.canonicalChatTitle,
                preview: "Scripted canonical chat",
                messageCount: 3)
        ])
    }

    func createCanonicalChat(profile: String) async throws -> String {
        created.insert(profile)
        return "botchat-\(profile)"
    }
}

/// R9-T5/T6: scripted management seam (DEBUG simulator only) — fixture
/// cron jobs + skills catalog with in-memory mutations so both panes are
/// fully walkable without a live gateway. Presentation data only.
///
/// Slice 3 (D13): the cron store is PROFILE-SCOPED like the real gateway
/// (cron/jobs.py:59-64 — each profile's jobs live in its own store). The
/// fixture seeds general jobs plus deterministic `[bot:<owner>]` routine
/// jobs so the bot Routines surface has walkable content: list returns
/// the general jobs plus the requesting profile's namespaced routines.
final class ScriptedManagementSeam: GatewayManagementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [CronJob]
    private var disabled: Set<String>

    init(gatewayID: GatewayID) {
        // The outage gateway gets no jobs (honest partial-fleet state);
        // healthy gateways get the fixture set.
        if gatewayID.rawValue == "arch" {
            jobs = []
            disabled = []
        } else {
            jobs = [
                CronJob(
                    jobID: "script-cron-1", name: "Fleet morning briefing",
                    schedule: "every day at 07:00",
                    nextRunAt: "2026-09-05T07:00:00", lastRunAt: "2026-09-04T07:00:03",
                    lastStatus: "ok", isEnabled: true, state: "enabled",
                    promptPreview: "Summarize fleet activity since yesterday and flag stuck cards."),
                CronJob(
                    jobID: "script-cron-2", name: "Weekly digest",
                    schedule: "every monday at 09:00",
                    nextRunAt: nil, lastRunAt: nil, lastStatus: nil,
                    isEnabled: false, state: "paused", promptPreview: nil),
                // Slice 3 fixture routines — the researcher bot's store.
                CronJob(
                    jobID: "script-routine-1", name: "[bot:researcher] Morning briefing",
                    schedule: "every day at 07:00",
                    nextRunAt: "2026-09-08T07:00:00", lastRunAt: "2026-09-07T07:00:02",
                    lastStatus: "ok", isEnabled: true, state: "enabled",
                    promptPreview: "Summarize overnight fleet activity for the researcher.",
                    deliver: "bot-chat:researcher", repeatDisplay: "forever"),
                CronJob(
                    jobID: "script-routine-2", name: "[bot:researcher] Weekly digest",
                    schedule: "every monday at 09:00",
                    nextRunAt: nil, lastRunAt: nil, lastStatus: nil,
                    isEnabled: false, state: "paused", promptPreview: nil,
                    pausedReason: "paused by user"),
                // Slice 3 fixture routine — the default bot's store, with a
                // deterministic failure association (last_fire_error).
                CronJob(
                    jobID: "script-routine-3", name: "[bot:default] Evening recap",
                    schedule: "every day at 21:00",
                    nextRunAt: "2026-09-08T21:00:00", lastRunAt: "2026-09-07T21:00:04",
                    lastStatus: "fire_failed", isEnabled: true, state: "enabled",
                    promptPreview: "Recap the day's fleet activity.",
                    deliver: "bot-chat:default", repeatDisplay: "forever",
                    lastFireError: "provider auth missing for openrouter"),
            ]
            disabled = ["test-driven-development"]
        }
    }

    /// Async-safe scoped lock helper (NSLock is unavailable in async
    /// contexts on this toolchain — same helper as ScriptedKanbanWatcher).
    private func unlocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func listCronJobs(profile: String?) async throws -> [CronJob] {
        unlocked {
            // Profile-scoped store: general jobs plus THIS profile's
            // namespaced routines (the [bot:<profile>] namespace is the
            // ownership association on the real wire too).
            jobs.filter { job in
                guard let profile else { return true }
                if let parsed = BotRoutineNamespace.parse(job.name) {
                    return parsed.owner.lowercased() == profile.lowercased()
                }
                return true
            }
        }
    }

    func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
        let job = CronJob(
            jobID: "script-cron-\(UUID().uuidString.prefix(6))",
            name: draft.name, schedule: draft.schedule,
            nextRunAt: "2026-09-05T07:00:00", isEnabled: true, state: "enabled",
            promptPreview: String(draft.prompt.prefix(80)),
            deliver: draft.deliver,
            repeatDisplay: draft.repeatCount.map { _ in "forever" })
        return unlocked {
            jobs.append(job)
            return job
        }
    }

    func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
        // Two-phase so the throwing guard runs OUTSIDE the scoped helper
        // (unlocked's body is non-throwing).
        let index = unlocked { jobs.firstIndex { $0.jobID == jobID } }
        guard let index else {
            throw GatewayManagementError.rpcFailed("no such job")
        }
        return unlocked {
            let old = jobs[index]
            let updated = CronJob(
                jobID: old.jobID, name: old.name, schedule: old.schedule,
                nextRunAt: enabled ? "2026-09-05T07:00:00" : nil,
                lastRunAt: old.lastRunAt, lastStatus: old.lastStatus,
                isEnabled: enabled, state: enabled ? "enabled" : "paused",
                promptPreview: old.promptPreview)
            jobs[index] = updated
            return updated
        }
    }

    func deleteCronJob(_ jobID: String, profile: String?) async throws {
        unlocked { jobs.removeAll { $0.jobID == jobID } }
    }

    func fireCronJob(_ jobID: String, profile: String?) async throws {
        // Scripted success — the fixture gateway "supports" run-over-WS.
    }

    func skillsCatalog(profile: String) async throws -> SkillsCatalog {
        // Mirrors the live 0.21.0 server: `skills.manage list` EXCLUDES
        // disabled skills (tools/skills_tool.py:773) with no include flag
        // on the WS handler (methods_tools.py:1916-1919), while
        // `profiles.describe` reports the full installed set with
        // enablement (methods_profiles.py:625-640). The union join in
        // SkillsCatalog restores the disabled names under `installed`.
        let disabledNow = unlocked { disabled }
        let allCategories: [(category: String, skills: [String])] = [
            ("dev", ["codex", "systematic-debugging", "test-driven-development"]),
            ("github", ["github-code-review", "github-pr-workflow", "github-auth"]),
            ("hermes", ["hermes-agent"]),
        ]
        let visibleCategories = allCategories
            .map { (category: $0.category, skills: $0.skills.filter { !disabledNow.contains($0.lowercased()) }) }
            .filter { !$0.skills.isEmpty }
        let described = allCategories.flatMap { $0.skills }
        let enabledByName = Dictionary(
            uniqueKeysWithValues: described.map { name in
                (name.lowercased(), !disabledNow.contains(name.lowercased()))
            })
        return SkillsCatalog(
            unionOf: visibleCategories, describedSkills: enabledByName)
    }

    func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
        unlocked {
            if enabled {
                disabled.remove(name.lowercased())
            } else {
                disabled.insert(name.lowercased())
            }
            return enabled
        }
    }
}

/// R9-T7: scripted learning seam (DEBUG simulator only) — a fixture
/// learning journey (mirrors the live mac profile's real shape: learned
/// skills + memory chunks across date buckets) so the Memory Graph is
/// fully walkable without a live gateway. Presentation data only.
final class ScriptedLearningSeam: GatewayLearningProviding, @unchecked Sendable {

    private let state = OSAllocatedUnfairLock(initialState: ScriptedLearningSeam.fixtureGraph())

    init(gatewayID: GatewayID) {}

    func learningGraph(profile: String?) async throws -> LearningGraph {
        state.withLock { $0 }
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
        let isMemory = id.hasPrefix("memory:")
        return LearningNodeDetail(
            id: id,
            kind: isMemory ? "memory" : "skill",
            label: id,
            // Single-word memory body: a double-tap selects the whole
            // chunk, which keeps the UI-test edit-clearing deterministic.
            content: isMemory
                ? "fixturechunk"
                : "---\nname: \(id)\ndescription: Fixture skill for the simulator walkthrough.\n---\n\n(fixture SKILL.md body)")
    }

    func editNode(id: String, content: String) async throws -> String {
        // Wire-truth refusal (learning_mutations.py:150-153): an empty
        // memory body is refused with the real message — the honest UI
        // walkthrough of a gateway refusal, no env hook needed.
        if id.hasPrefix("memory:"), content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GatewayLearningError.mutationFailed("empty memory — use delete to remove it")
        }
        // The fixture graph does not track chunk content; a real reload
        // after edit still succeeds and keeps node count stable.
        return id.hasPrefix("memory:")
            ? "updated memory in MEMORY.md"
            : "updated '\(id)'"
    }

    func deleteNode(id: String) async throws -> String {
        state.withLock { state in
            state = LearningGraph(
                buckets: state.buckets.map { bucket in
                    LearningGraphBucket(
                        index: bucket.index, label: bucket.label, date: bucket.date,
                        category: bucket.category,
                        nodes: bucket.nodes.filter { $0.id != id })
                },
                summary: state.summary)
        }
        return id.hasPrefix("memory:")
            ? "deleted memory from MEMORY.md"
            : "archived '\(id)' — restore with: hermes curator restore \(id)"
    }

    /// A fixture journey shaped like the live payload (buckets with skills
    /// + memories, summary/axis/count) — deterministic.
    static func fixtureGraph() -> LearningGraph {
        var buckets: [LearningGraphBucket] = []
        let plan: [(label: String, date: String, skills: [String], memories: [String])] = [
            ("30 Aug", "30 Aug 2026", ["systematic-debugging"], []),
            ("31 Aug", "31 Aug 2026", ["github-auth"], ["memory:profile:0"]),
            ("1 Sep", "1 Sep 2026", ["codex", "hermes-agent"], ["memory:memory:1"]),
            ("2 Sep", "2 Sep 2026", ["test-driven-development"], ["memory:profile:2"]),
            ("3 Sep", "3 Sep 2026", ["github-code-review", "github-pr-workflow"], []),
            ("4 Sep", "4 Sep 2026", ["ios-xcode-project-pipeline", "swift-and-platform-engineering", "apple-product-factory"], ["memory:memory:3"]),
        ]
        for (index, slice) in plan.enumerated() {
            var nodes: [LearningGraphNode] = slice.skills.map {
                LearningGraphNode(
                    id: $0, label: $0, fullLabel: $0, isMemory: false,
                    meta: "skill · \(slice.date) · x\(2 + index)")
            }
            nodes.append(contentsOf: slice.memories.map {
                LearningGraphNode(
                    id: $0, label: "profile memory", fullLabel: "profile memory",
                    isMemory: true, meta: "memory · \(slice.date)",
                    body: "# profile memory\n\nchunk…")
            })
            buckets.append(LearningGraphBucket(
                index: index, label: slice.label, date: slice.date,
                category: index % 2 == 0 ? "dev" : "software-development",
                nodes: nodes))
        }
        let skillCount = plan.reduce(0) { $0 + $1.skills.count }
        let memoryCount = plan.reduce(0) { $0 + $1.memories.count }
        return LearningGraph(
            buckets: buckets,
            summary: LearningGraphSummary(
                lines: ["\(skillCount) learned skills · \(memoryCount) memories · 9 skill links",
                        "\(memoryCount) memory↔skill links · busiest day 4 Sep · 4 learned"],
                start: "30 Aug 2026", end: "4 Sep 2026",
                totalCount: skillCount + memoryCount))
    }
}

/// R10-T3: scripted projects seam (DEBUG simulator only) — a fixture
/// projects.tree mirroring the live gateway's real shape (an explicit
/// project with two lanes + the "No Project" tier, previews on the
/// overview, hydrated rows on drill-in) so the Projects browser is
/// fully walkable without a live gateway. Presentation data only.
///
/// Failure hook (`HERMES_FLEET_PROJECTS_FAIL=1`) makes every call throw
/// 5061-shaped — the honest offline/error walkthrough for UI tests.
final class ScriptedProjectsSeam: GatewayProjectsProviding, @unchecked Sendable {

    private static let failHook =
        ProcessInfo.processInfo.environment["HERMES_FLEET_PROJECTS_FAIL"] == "1"

    init(gatewayID: GatewayID) {}

    func projectTree(profile: String?) async throws -> ProjectsTree {
        if Self.failHook {
            throw GatewayProjectsError.rpcFailed("profile db locked (5061)")
        }
        return Self.fixtureTree()
    }

    func projectSessions(projectID: String, profile: String?) async throws -> ProjectNode? {
        if Self.failHook {
            throw GatewayProjectsError.rpcFailed("profile db locked (5061)")
        }
        return Self.fixtureTree().projects.first { $0.id == projectID }
            .map(Self.hydrate)
    }

    func completePath(word: String, cwd: String?) async throws -> [PathCompletionItem] {
        if Self.failHook {
            throw GatewayProjectsError.rpcFailed("profile db locked (5061)")
        }
        // Scripted completions for the walkthrough only.
        switch word {
        case "@file:PACK", "@file:Packages/Fle":
            return [
                PathCompletionItem(text: "@folder:Packages/FleetUI/", display: "FleetUI/", meta: "dir"),
                PathCompletionItem(text: "@file:Packages/Module.swift", display: "Module.swift", meta: "Packages"),
            ]
        default:
            return []
        }
    }

    /// Fixture overview (hydrate=False shape: lanes carry no rows).
    static func fixtureTree() -> ProjectsTree {
        let sessionRow = { (id: String, title: String, preview: String, branch: String,
                            started: Double, active: Double, messages: Int, cost: Double) in
            ProjectSessionRow(
                id: id, title: title, preview: preview,
                startedAt: started, lastActive: active, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: branch,
                messageCount: messages, toolCallCount: messages / 4,
                inputTokens: messages * 50, outputTokens: messages * 75,
                actualCostUsd: cost, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default")
        }
        let fleet = ProjectNode(
            id: "proj-fleet", label: "Fleet iOS",
            path: "/Users/dev/code/fleet-ios", color: "#22d3ee",
            isAuto: false, isNoProject: false, sessionCount: 3,
            lastActive: 1_788_550_000, totalTokens: 1_500, totalCostUsd: 0.05,
            repos: [
                ProjectRepoNode(
                    id: "/Users/dev/code/fleet-ios", label: "fleet-ios",
                    path: "/Users/dev/code/fleet-ios", sessionCount: 3,
                    groups: [
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::branch::r10-t3",
                            label: "r10-t3", path: "/Users/dev/code/fleet-ios",
                            isMain: false, isKanban: false, sessions: []),
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::branch::main",
                            label: "main", path: "/Users/dev/code/fleet-ios",
                            isMain: true, isKanban: false, sessions: []),
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::kanban",
                            label: "kanban", path: "/Users/dev/code/fleet-ios",
                            isMain: false, isKanban: true, sessions: []),
                    ]),
            ],
            previewSessions: [
                sessionRow("s1", "WS transport fix", "correlate rpc ids", "r10-t3",
                           1_788_540_000, 1_788_550_000, 12, 0.04),
                sessionRow("s2", "Reactions round 2", "promote newest_role", "main",
                           1_788_500_000, 1_788_510_000, 8, 0.01),
                sessionRow("s3", "Board sweep", "qa findings", "main",
                           1_788_480_000, 1_788_490_000, 5, 0.00),
            ])
        let noProject = ProjectNode(
            id: "__no_project__", label: "No Project", path: nil, color: nil,
            isAuto: false, isNoProject: true, sessionCount: 1,
            lastActive: 1_788_540_000, totalTokens: 500, totalCostUsd: 0.01,
            repos: [
                ProjectRepoNode(
                    id: "__no_project__", label: "No Project", path: nil, sessionCount: 1,
                    groups: [
                        ProjectLaneNode(
                            id: "__no_project__", label: "No Project", path: nil,
                            isMain: false, isKanban: false, sessions: [])]),
            ],
            previewSessions: [
                ProjectSessionRow(
                    id: "s9", title: "Loose scratch chat", preview: "quick question",
                    startedAt: 1_788_530_000, lastActive: 1_788_540_000, endedAt: nil,
                    cwd: "/tmp", gitBranch: "", messageCount: 2, toolCallCount: 0,
                    inputTokens: 200, outputTokens: 300,
                    actualCostUsd: 0.01, estimatedCostUsd: nil,
                    model: "glm-5.3", profile: "default"),
            ])
        return ProjectsTree(
            projects: [noProject, fleet],
            activeID: "proj-fleet",
            scopedSessionIDs: ["s9", "s1", "s2", "s3"])
    }

    /// Fixture drill-in (hydrate=True shape: lanes carry rows).
    static func hydrate(_ node: ProjectNode) -> ProjectNode {
        let rows: [String: ProjectSessionRow] = [
            "s1": ProjectSessionRow(
                id: "s1", title: "WS transport fix", preview: "correlate rpc ids",
                startedAt: 1_788_540_000, lastActive: 1_788_550_000, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: "r10-t3",
                messageCount: 12, toolCallCount: 3, inputTokens: 600, outputTokens: 900,
                actualCostUsd: 0.04, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default"),
            "s2": ProjectSessionRow(
                id: "s2", title: "Reactions round 2", preview: "promote newest_role",
                startedAt: 1_788_500_000, lastActive: 1_788_510_000, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: "main",
                messageCount: 8, toolCallCount: 0, inputTokens: 100, outputTokens: 200,
                actualCostUsd: 0.01, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default"),
            "s3": ProjectSessionRow(
                id: "s3", title: "Board sweep", preview: "qa findings",
                startedAt: 1_788_480_000, lastActive: 1_788_490_000, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: "main",
                messageCount: 5, toolCallCount: 1, inputTokens: 250, outputTokens: 375,
                actualCostUsd: 0.0, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default"),
        ]
        let hydratedRepos = node.repos.map { repo in
            ProjectRepoNode(
                id: repo.id, label: repo.label, path: repo.path,
                sessionCount: repo.sessionCount,
                groups: repo.groups.map { lane in
                    ProjectLaneNode(
                        id: lane.id, label: lane.label, path: lane.path,
                        isMain: lane.isMain, isKanban: lane.isKanban,
                        sessions: lane.id.hasSuffix("::kanban")
                            ? []
                            : lane.label.replacements(rowCount: lane.isMain ? 2 : 1).compactMap { rows[$0] })
                })
        }
        return ProjectNode(
            id: node.id, label: node.label, path: node.path, color: node.color,
            isAuto: node.isAuto, isNoProject: node.isNoProject,
            sessionCount: node.sessionCount, lastActive: node.lastActive,
            totalTokens: node.totalTokens, totalCostUsd: node.totalCostUsd,
            repos: hydratedRepos, previewSessions: [])
    }
}

/// Tiny helper: deterministic session-id pick per lane for the fixture.
private extension String {
    func replacements(rowCount: Int) -> [String] {
        switch self {
        case "r10-t3": return rowCount >= 1 ? ["s1"] : []
        case "main": return rowCount >= 2 ? ["s2", "s3"] : (rowCount == 1 ? ["s2"] : [])
        default: return []
        }
    }
}

/// Scripted per-gateway conversation session (DEBUG only): a scripted
/// connection + a scripted conversation client that streams a canned turn
/// (message.start → deltas → message.complete) after each prompt.submit, a
/// no-op replay (nothing to replay), and scripted history. Makes the U3
/// Conversation canvas fully walkable in the simulator without a live gateway.
private struct ScriptedConversationSession: ConversationSessionProviding, ApprovalsCapable, ConversationToolingCapable, AttachmentStagingCapable, ReactionCapable {
    let gatewayID: GatewayID
    private let client: ScriptedConversationClient
    /// R9-T1: scripted approvals seam (records respond/yolo calls so the
    /// approval banner is fully walkable in the simulator + UI tests).
    let approvalsBox = ScriptedApprovalsBox()
    /// R9-T2/T3/T4: scripted tooling seam (fixture models + usage +
    /// steer/title/branch recorders).
    let toolingBox = ScriptedToolingBox()
    /// R10-T1: scripted attachment-staging seam (fixture refs + failure
    /// hooks so the composer tray is fully walkable in the simulator + UI
    /// tests).
    let attachmentsBox = ScriptedAttachmentSeam()
    /// R10-T2: scripted reaction seam (records react calls + failure hook so
    /// long-press Tapback is fully walkable in the simulator + UI tests).
    let reactionsBox = ScriptedReactionSeam()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        self.client = ScriptedConversationClient(gatewayID: gatewayID)
        // R10-T2: keep the scripted reaction seam's durable-row state in
        // lockstep with the fixture resume projection (the seeded 👀 on
        // row 9101), so a same-emoji re-send retracts exactly like the DB
        // layer would.
        reactionsBox.seedReactions(
            [MessageReaction(emoji: "👀", author: "user", at: 1_788_600_000)],
            rowID: "9101")
    }

    var status: GatewayStatus {
        // The `arch` gateway is scripted UNREACHABLE (partial-outage demo).
        gatewayID.rawValue == "arch" ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        gatewayID.rawValue == "arch"
            ? nil
            : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if gatewayID.rawValue == "arch" {
            throw GatewayConnectivityError.unreachable
        }
    }

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func reauthenticate() async throws {
        if gatewayID.rawValue == "arch" {
            throw GatewayConnectivityError.unreachable
        }
    }

    var conversation: any ConversationProviding {
        client
    }

    var approvals: any ApprovalsProviding {
        approvalsBox
    }

    /// R9-T2/T3/T4: scripted tooling seam.
    var tooling: any ConversationToolingProviding {
        toolingBox
    }

    /// R10-T1: scripted attachment-staging seam.
    var attachments: any AttachmentStagingProviding {
        attachmentsBox
    }

    /// R10-T2: scripted reaction seam.
    var reactions: any ReactionProviding {
        reactionsBox
    }

    /// R9-T1 UI-test hook: push a scripted approval request into the
    /// conversation event stream (drives the banner deterministically).
    func pushApprovalRequest(_ request: ApprovalRequest) {
        client.pushApprovalRequest(request)
    }

    var replay: any ReplayProviding {
        ScriptedReplay(gatewayID: gatewayID)
    }

    var history: any SessionHistoryProviding {
        ScriptedHistory(gatewayID: gatewayID)
    }
}

/// Scripted `ConversationProviding` that streams a canned turn after submit.
private final class ScriptedConversationClient: ConversationProviding, @unchecked Sendable {
    private let gatewayID: GatewayID
    private let streamBox = ScriptedEventStreamBox()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    var events: AsyncStream<ConversationEvent> {
        streamBox.stream
    }

    /// R9-T1 UI-test hook: yield a scripted approval.request into the event
    /// fan-out (the banner renders from the same conversation stream).
    func pushApprovalRequest(_ request: ApprovalRequest) {
        streamBox.yield(.approvalRequested(
            sessionID: request.sessionID,
            requestID: request.requestID,
            command: request.command,
            detail: request.detail,
            choices: request.choices
        ))
    }

    func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
        // R9-T2: honor the per-session model override (the sticky pick rides
        // here) — the scripted session reflects the requested model back.
        ConversationSession(
            sessionID: "scripted-\(gatewayID.rawValue)",
            storedSessionID: "stored-scripted-\(gatewayID.rawValue)",
            messageCount: 0,
            messages: [],
            model: model ?? "scripted-model",
            provider: provider ?? "simulator",
            profileName: profile
        )
    }

    func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
        // R10-T2: fixture durable rows (row_id-stamped, one carrying a
        // seeded reaction) so long-press Tapback targets DURABLE rows in
        // the simulator + UI tests — mirroring what a real session.resume
        // projection carries.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_REACTION_FIXTURE"] == "1" {
            return ConversationSession(
                sessionID: sessionID,
                storedSessionID: "stored-\(sessionID)",
                messageCount: 2,
                messages: [
                    SessionMessage(
                        role: .user,
                        text: "Reaction fixture row — long-press me",
                        rowID: "9100"),
                    SessionMessage(
                        role: .assistant,
                        text: "Fixture answer with a seeded reaction.",
                        rowID: "9101",
                        reactions: [MessageReaction(emoji: "👀", author: "user", at: 1_788_600_000)]),
                ],
                model: "scripted-model",
                provider: "simulator",
                profileName: nil
            )
        }
        // R10-T3 round 2 UI-test hook: fixture durable rows carrying an
        // `@file:` ref whose ABSOLUTE path lands inside the scripted
        // projects tree's repo (so the tap-through highlights its
        // containing project) — mirrors what a real transcript row with
        // an attached-file reference looks like on the wire.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_FILEREF_FIXTURE"] == "1" {
            return ConversationSession(
                sessionID: sessionID,
                storedSessionID: "stored-\(sessionID)",
                messageCount: 2,
                messages: [
                    SessionMessage(
                        role: .user,
                        text: "Please review @file:/Users/dev/code/fleet-ios/Packages/FleetUI/ProjectsView.swift before merging",
                        rowID: "9200"),
                    SessionMessage(
                        role: .assistant,
                        text: "Reviewed. The ProjectsView drills via projects.project_sessions.",
                        rowID: "9201"),
                ],
                model: "scripted-model",
                provider: "simulator",
                profileName: nil
            )
        }
        return ConversationSession(
            sessionID: sessionID,
            storedSessionID: "stored-\(sessionID)",
            messageCount: 0,
            messages: [],
            model: "scripted-model",
            provider: "simulator",
            profileName: nil
        )
    }

    /// t_8401d3c3: the scripted simulator never gaps — nothing to resume.
    func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] {
        []
    }

    func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        // R9-T1 demo hook (simulator only): `HERMES_FLEET_APPROVAL_DEMO=1`
        // makes every scripted turn also raise an approval request mid-turn
        // — the banner is then fully walkable in the simulator + UI tests.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_APPROVAL_DEMO"] == "1" {
            Task { [streamBox] in
                try? await Task.sleep(for: .milliseconds(400))
                streamBox.yield(.approvalRequested(
                    sessionID: sessionID,
                    requestID: "scripted-approval-1",
                    // Fixture token is FAKE (demo only) — allowline-annotated
                    // because the gitleaks curl-auth-header regex matches any
                    // token-shaped bearer literal regardless of validity.
                    command: "rm -rf /tmp/scratch && curl -H 'Authorization: Bearer sk-live-demo' https://api", // gitleaks:allow
                    detail: "Scripted dangerous command (simulator demo)",
                    choices: ["once", "session", "always", "deny"]
                ))
            }
        }
        // Stream a canned assistant turn shortly after submit (async so the
        // view model's event subscription is attached). R9-T3: a mid-turn
        // session.usage tick exercises the live context meter path.
        Task { [streamBox] in
            try? await Task.sleep(for: .milliseconds(250))
            streamBox.yield(.usageUpdate(
                sessionID: sessionID,
                usage: SessionUsageSnapshot(
                    model: "hermes",
                    input: 12_000,
                    output: 1_200,
                    total: 13_200,
                    calls: 2,
                    contextUsed: 52_000,
                    contextMax: 120_000,
                    contextPercent: 43
                )
            ))
            streamBox.yield(.messageStart(sessionID: sessionID))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "Hello from the scripted fleet. ", rendered: nil))
            // D-2 fix (t_9ce36690): echo the PROMPT TEXT only — drop the
            // appended @file:/@folder: ref TOKENS from the echoed text (the
            // ref marker AND its path; refs stay visible in the user bubble
            // + its tap-through chip, and the wire shape is unchanged — refs
            // are staged server-side at pick time). Empirically (9-run
            // experiment matrix), an assistant bubble — a textSelection-
            // enabled Text — carrying a long unbreakable @file: path token
            // makes every iOS 26 AX identifier-snapshot take >30s, wedging
            // XCUITest queries (R10AttachmentTray line-79 timeout). Short
            // plain-text echoes keep the "You said: <text>" contract
            // asserted by HappyPath/P0-7.
            let echoBase = text
                .split(whereSeparator: \.isWhitespace)
                .filter { !$0.contains("@file:") && !$0.contains("@folder:") }
                .joined(separator: " ")
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "You said: ", rendered: nil))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: echoBase, rendered: nil))
            streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
            streamBox.yield(.messageComplete(
                sessionID: sessionID,
                text: "Hello from the scripted fleet. You said: \(echoBase)",
                status: nil,
                error: nil
            ))
        }
        return PromptSubmission(status: "streaming")
    }

    func interrupt(sessionID: String) async throws -> InterruptResult {
        InterruptResult(status: "interrupted")
    }
}

/// R9-T1: scripted approvals seam (DEBUG simulator). Records every
/// respond/yolo call (thread-safe) and succeeds — the banner's wire path is
/// observable from UI tests via the recorded state.
final class ScriptedApprovalsBox: ApprovalsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _respondChoices: [String] = []
    private var _yoloStates: [Bool] = []

    var respondChoices: [String] {
        lock.lock(); defer { lock.unlock() }
        return _respondChoices
    }
    var yoloStates: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _yoloStates
    }

    // Sync-record helpers (NSLock is unavailable from async contexts).
    private func recordRespond(_ raw: String) {
        lock.lock(); defer { lock.unlock() }
        _respondChoices.append(raw)
    }
    private func recordYolo(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        _yoloStates.append(enabled)
    }

    func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
        recordRespond(choice.rawValue)
        return 1
    }

    func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool {
        recordYolo(enabled)
        return enabled
    }

    /// R9-T1 rework: restore seam — no scripted pendings by default (the
    /// demo approval arrives as a push event, not a reconnect restore).
    func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        []
    }
}

/// R9-T2/T3/T4: scripted tooling seam (DEBUG simulator). Deterministic
/// fixture models for the picker; records steer/rename/branch calls; usage
/// readback with a mid-turn context gauge. Thread-safe recorders.
final class ScriptedToolingBox: ConversationToolingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _steerTexts: [String] = []
    private var _renames: [String] = []
    private var _branches: [String?] = []

    var steerTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _steerTexts
    }
    var renames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _renames
    }
    var branches: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _branches
    }

    private func recordSteer(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _steerTexts.append(text)
    }
    private func recordRename(_ title: String) {
        lock.lock(); defer { lock.unlock() }
        _renames.append(title)
    }
    private func recordBranch(_ name: String?) {
        lock.lock(); defer { lock.unlock() }
        _branches.append(name)
    }

    /// Fixture models (deterministic, mono ids — the picker's UI-test set).
    func modelChoices(sessionID: String?) async throws -> [ModelChoice] {
        [
            ModelChoice(model: "hermes", provider: "nous", providerName: "Nous Research", isCurrent: true),
            ModelChoice(model: "hermes-mini", provider: "nous", providerName: "Nous Research", isCurrent: false),
            ModelChoice(model: "openai/gpt-5", provider: "openrouter", providerName: "OpenRouter", isCurrent: false),
            ModelChoice(model: "anthropic/claude-sonnet-4", provider: "openrouter", providerName: "OpenRouter", isCurrent: false),
        ]
    }

    /// Usage readback with a mid-context gauge (fixture: 38% of 120k).
    func usage(sessionID: String) async throws -> SessionUsageSnapshot {
        SessionUsageSnapshot(
            model: "hermes",
            input: 12_000,
            output: 3_400,
            total: 16_300,
            calls: 4,
            contextUsed: 45_600,
            contextMax: 120_000,
            contextPercent: 38
        )
    }

    /// Fixture breakdown mirroring context_breakdown.py:163's category set.
    func contextBreakdown(sessionID: String) async throws -> ContextBreakdown {
        ContextBreakdown(
            categories: [
                ContextBreakdownCategory(id: "system_prompt", label: "System prompt", tokens: 5_200),
                ContextBreakdownCategory(id: "tool_definitions", label: "Tool definitions", tokens: 9_800),
                ContextBreakdownCategory(id: "rules", label: "Rules", tokens: 1_400),
                ContextBreakdownCategory(id: "skills", label: "Skills", tokens: 2_100),
                ContextBreakdownCategory(id: "mcp", label: "MCP", tokens: 0),
                ContextBreakdownCategory(id: "subagent_definitions", label: "Subagent definitions", tokens: 1_100),
                ContextBreakdownCategory(id: "memory", label: "Memory", tokens: 3_400),
                ContextBreakdownCategory(id: "conversation", label: "Conversation", tokens: 22_600),
            ].filter { $0.tokens > 0 },
            contextMax: 120_000,
            contextPercent: 38,
            contextUsed: 45_600,
            estimatedTotal: 45_600,
            model: "hermes"
        )
    }

    func steer(sessionID: String, text: String) async throws -> Bool {
        recordSteer(text)
        return true
    }

    func renameSession(sessionID: String, title: String) async throws -> String {
        recordRename(title)
        return title
    }

    func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
        recordBranch(name)
        return ConversationSession(
            sessionID: "scripted-branch-\(sessionID)",
            storedSessionID: "stored-\(sessionID)-branch",
            messageCount: 2,
            messages: [
                SessionMessage(role: .user, text: "hello fixture"),
                SessionMessage(role: .assistant, text: "Hi from the scripted branch."),
            ],
            model: "hermes",
            provider: "simulator",
            profileName: nil
        )
    }
}

/// R10-T1: scripted attachment-staging seam (DEBUG simulator only).
/// Deterministic fixture `@file:` refs shaped like the live gateway's
/// `file.attach` result (methods_prompt.py:1350-1395); records every attach
/// call so UI tests assert the wire-shaped ask. Failure hook
/// (`HERMES_FLEET_ATTACHMENT_FAIL=1`) makes every attach throw 4018-shaped
/// `tooLarge` so the never-silent error banner is walkable.
final class ScriptedAttachmentSeam: AttachmentStagingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _attachCalls: [(method: String, sessionID: String, name: String)] = []

    /// Recorded attach calls (method, session, name) — UI-test observability.
    var attachCalls: [(method: String, sessionID: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        return _attachCalls
    }

    private func record(_ method: String, _ sessionID: String, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        _attachCalls.append((method, sessionID, name))
    }

    private var failAll: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_ATTACHMENT_FAIL"] == "1"
    }

    func attachFile(sessionID: String, name: String, dataURL: String) async throws -> StagedFileAttachment {
        record("file.attach", sessionID, name)
        if failAll {
            throw AttachmentStagingError.tooLarge(detail: "fixture: file too large (UI-test failure hook)")
        }
        let display = (name as NSString).lastPathComponent
        return StagedFileAttachment(
            name: display,
            path: "/srv/hermes/profiles/default/attachments/\(display)",
            refPath: "attachments/\(display)",
            refText: "@file:attachments/\(display)",
            uploaded: true)
    }

    func attachImageBytes(sessionID: String, filename: String, dataURL: String) async throws -> StagedImageAttachment {
        record("image.attach_bytes", sessionID, filename)
        if failAll {
            throw AttachmentStagingError.tooLarge(detail: "fixture: image too large (UI-test failure hook)")
        }
        return StagedImageAttachment(
            path: "/srv/hermes/images/upload_fixture_1.png",
            name: "upload_fixture_1.png",
            count: 1,
            byteCount: 1_024,
            width: 64,
            height: 64,
            tokenEstimate: 320)
    }

    func attachPDF(sessionID: String, filename: String, dataURL: String) async throws -> StagedPDFAttachment {
        record("pdf.attach", sessionID, filename)
        if failAll {
            throw AttachmentStagingError.tooLarge(detail: "fixture: PDF too large (UI-test failure hook)")
        }
        return StagedPDFAttachment(
            filename: (filename as NSString).lastPathComponent,
            pagesAttached: 2,
            pages: [
                StagedPDFPage(path: "/srv/hermes/images/pdf_p1_1.png", pageNumber: 1,
                              name: "pdf_p1_1.png", width: 1275, height: 1650),
                StagedPDFPage(path: "/srv/hermes/images/pdf_p2_2.png", pageNumber: 2,
                              name: "pdf_p2_2.png", width: 1275, height: 1650),
            ],
            count: 2)
    }

    func detachImage(sessionID: String, path: String) async throws -> DetachedImageState {
        DetachedImageState(detached: true, count: 0)
    }
}

/// R10-T2: scripted reaction seam — records every `message.react` call so
/// UI tests assert the wire-shaped ask (row_id vs newest_role, emoji vs
/// null). Failure hook (`HERMES_FLEET_REACTION_FAIL=1`) makes every react
/// throw 4040-shaped `messageNotFound` so the never-silent error banner +
/// optimistic rollback are walkable. Result discipline mirrors the server:
/// the post-write reaction list reflects the per-author single-reaction
/// semantics (re-send same emoji retracts).
final class ScriptedReactionSeam: ReactionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _reactCalls: [(sessionID: String, target: MessageReactionTarget, emoji: String?)] = []
    private var _reactions: [String: [MessageReaction]] = [:]

    /// Recorded react calls — UI-test observability.
    var reactCalls: [(sessionID: String, target: MessageReactionTarget, emoji: String?)] {
        lock.lock(); defer { lock.unlock() }
        return _reactCalls
    }

    /// Seed a row's reactions (fixture history adoption).
    func seedReactions(_ reactions: [MessageReaction], rowID: String) {
        lock.lock(); defer { lock.unlock() }
        _reactions[rowID] = reactions
    }

    private var failAll: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_REACTION_FAIL"] == "1"
    }

    func react(
        sessionID: String,
        target: MessageReactionTarget,
        emoji: String?
    ) async throws -> MessageReactionResult {
        let failing = failAll
        let result: MessageReactionResult = try lock.withLock {
            _reactCalls.append((sessionID, target, emoji))
            // Resolve the durable row the write lands on (mirrors
            // latest_message_row_id for newest_role — the scripted fleet has
            // no DB, so live targets land on the fixed fixture row).
            let rowID = target.rowID ?? "9101"
            var reactions = _reactions[rowID] ?? []
            if !failing, let emoji {
                // Server semantics (hermes_state.set_message_reaction):
                // re-sending the same emoji retracts; different replaces.
                let hadSame = reactions.contains { $0.author == "user" && $0.emoji == emoji }
                reactions.removeAll { $0.author == "user" }
                if !hadSame {
                    reactions.append(MessageReaction(emoji: emoji, author: "user", at: 1_788_600_000))
                }
                _reactions[rowID] = reactions
            } else if !failing {
                reactions.removeAll { $0.author == "user" }
                _reactions[rowID] = reactions
            }
            return MessageReactionResult(rowID: rowID, reactions: reactions)
        }
        if failing {
            throw ReactionError.messageNotFound("fixture: message not found (UI-test failure hook)")
        }
        return result
    }
}

/// Thread-safe fan-out box bridging the scripted client's event channel to
/// the `AsyncStream`s the view model subscribes to. P0-7: each `stream`
/// access returns a FRESH stream registered in the fan-out (deregistered on
/// termination), mirroring the real transport's multi-subscriber event
/// channel — a re-entered conversation (new view model after pop) gets a
/// live pipe instead of the previous consumer's dead one.
private final class ScriptedEventStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ConversationEvent>.Continuation] = [:]

    init() {}

    var stream: AsyncStream<ConversationEvent> {
        lock.lock()
        defer { lock.unlock() }
        let (stream, continuation) = AsyncStream<ConversationEvent>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    private func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        _ = continuations.removeValue(forKey: id)
    }

    func yield(_ event: ConversationEvent) {
        lock.lock()
        defer { lock.unlock() }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}

/// Scripted no-op replay (DEBUG only) — nothing was missed in the simulator.
private struct ScriptedReplay: ReplayProviding {
    let gatewayID: GatewayID
    func watermarks() async -> [SessionEventWatermark] { [] }
    func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
}

/// Scripted read-only history (DEBUG only). Canonical "Bot Chat" fixture
/// sessions (id prefix "botchat-") carry a short deterministic transcript so
/// the canonical-chat state is reviewable in the simulator; other sessions
/// stay honestly empty.
private struct ScriptedHistory: SessionHistoryProviding {
    let gatewayID: GatewayID
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        guard sessionID.hasPrefix("botchat-") else {
            return SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        let profile = String(sessionID.dropFirst("botchat-".count))
        let messages = [
            SessionMessage(
                role: .user,
                text: "Morning check-in — anything blocking you?",
                timestamp: 1_757_240_000,
                rowID: "botchat-hist-1"),
            SessionMessage(
                role: .assistant,
                text: "Nothing blocking. I finished the \(profile) review pass and queued the summary.",
                timestamp: 1_757_240_060,
                rowID: "botchat-hist-2"),
            SessionMessage(
                role: .user,
                text: "Great — ping me if the batch job drifts.",
                timestamp: 1_757_240_180,
                rowID: "botchat-hist-3"),
        ]
        return SessionHistory(sessionID: sessionID, count: messages.count, messages: messages)
    }
    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus.parse(output: "Session ID: \(sessionID)")
    }
}

/// Deterministic in-memory fleet for the simulator: three gateways (two
/// healthy, one unreachable) each with a couple of bots (profiles) and
/// sessions, so every navigation destination and the partial-outage roster
/// state have content.
enum ScriptedFleet {
    static let registrations: [GatewayRegistration] = [
        GatewayRegistration(
            id: GatewayID(rawValue: "workstation"),
            displayName: "Workstation",
            endpoint: URL(string: "http://127.0.0.1:8642")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "render-box"),
            displayName: "Render Box",
            endpoint: URL(string: "http://127.0.0.1:9900")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "arch"),
            displayName: "Lab Node",
            endpoint: URL(string: "http://127.0.0.1:9910")!
        ),
    ]

    static func profiles(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        // Slice 2: profiles created through the scripted management seam in
        // THIS app process join the roster on the next refresh (created bots
        // must become visible; the seam mints them).
        let created = ScriptedBotProfileSeamStore.shared.createdDescriptors(on: gatewayID)
        switch gatewayID.rawValue {
        case "workstation":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 12, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
                ProfileDescriptor(
                    name: "researcher", path: "~/.hermes/profiles/researcher",
                    isDefault: false, model: "hermes", provider: "openrouter",
                    displayName: "Researcher", skillCount: 8, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "researcher")
                ),
            ] + created
        case "render-box":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 10, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
            ] + created
        default:
            return created
        }
    }

    static func sessions(on route: Route) -> [SessionSummary] {
        switch route.gatewayID.rawValue {
        case "workstation":
            return [
                ScriptedFleet.session(on: "default"),
                SessionSummary(
                    id: "workstation.default.s2", title: "Replay plan review",
                    preview: "Discussing the reconnect/replay design.", startedAt: 1_755_000_000,
                    messageCount: 24, source: "ios"
                ),
            ]
        default:
            return [ScriptedFleet.session(on: route.profileSlug.rawValue)]
        }
    }

    private static func session(on slug: String) -> SessionSummary {
        SessionSummary(
            id: "workstation.\(slug).s1", title: "Fleet setup",
            preview: "Initial conversation about the Hermes fleet.",
            startedAt: 1_754_000_000, messageCount: 6, source: "ios"
        )
    }
}

/// Scripted single-gateway connection: connects instantly, adopts a ready
/// payload, never touches the network. Used for the Gateways screen lifecycle
/// and the registry probe. The `arch` gateway is scripted UNREACHABLE so the
/// simulator demonstrates the partial-outage state (§31).
private struct ScriptedGatewayConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID

    private var isOutage: Bool { gatewayID.rawValue == "arch" }

    var status: GatewayStatus {
        // Scripted connections report online immediately for healthy
        // gateways; the outage gateway reports offline so the observable
        // lifecycle state reflects partial availability.
        isOutage ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if isOutage {
            throw GatewayConnectivityError.unreachable
        }
        // No-op: scripted connect succeeds instantly.
    }

    func disconnect() async {
        // No-op: scripted disconnect is safe from every state (spec §31).
    }

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

/// P2-6 DEBUG-only seam: a `GatewayRegistryManaging` wrapper that throws on
/// the save path (add / update / saveCredential) while forwarding read +
/// teardown operations to the inner registry. Lets the deterministic UI test
/// drive the form's save-failure retry UX without a real transport failure.
private struct FailingSaveRegistry: GatewayRegistryManaging {
    let inner: any GatewayRegistryManaging

    func allGateways() async -> [FleetGateway] { await inner.allGateways() }
    func gateway(for id: GatewayID) async -> FleetGateway? { await inner.gateway(for: id) }
    func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        throw GatewayRegistryError.credentialStoreFailed("injected save failure")
    }
    func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        throw GatewayRegistryError.credentialStoreFailed("injected save failure")
    }
    func removeGateway(_ id: GatewayID) async throws { try await inner.removeGateway(id) }
    func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        throw GatewayRegistryError.credentialStoreFailed("injected save failure")
    }
    func clearCredential(for id: GatewayID) async throws { try await inner.clearCredential(for: id) }
    func hasCredential(for id: GatewayID) async -> Bool { await inner.hasCredential(for: id) }
    func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
        try await inner.testConnection(to: id)
    }
}

/// Scripted per-gateway roster session: real M8 session shape, scripted
/// `profiles.list` / `session.list` responses. The `arch` gateway is scripted
/// UNREACHABLE so the union roster refresh classifies it offline while the
/// healthy gateways still aggregate (spec §31 partial availability).
///
/// P2-5: when `HERMES_FLEET_ZERO_BOTS=1`, EVERY gateway reports a healthy,
/// zero-bot roster (no outage, no profiles) so the all-healthy all-empty state
/// is reachable for the No-Bots regression UI test.
private struct ScriptedRosterSession: GatewayRosterSession {
    let gatewayID: GatewayID

    private var isOutage: Bool {
        guard !FleetServiceGraph.zeroBotsEnabled else { return false }
        return gatewayID.rawValue == "arch"
    }

    private var hasNoBots: Bool { FleetServiceGraph.zeroBotsEnabled }

    var status: GatewayStatus { isOutage ? .offline : .online }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if isOutage {
            throw GatewayConnectivityError.unreachable
        }
    }

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func fetchProfiles() async throws -> [ProfileDescriptor] {
        if isOutage { throw RosterError.notConnected }
        if hasNoBots { return [] }
        return ScriptedFleet.profiles(on: gatewayID)
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        if isOutage { throw RosterError.notConnected }
        return ScriptedFleet.sessions(on: route)
    }
}

/// Shared record of profiles created through scripted management seams in
/// this app process, so the scripted roster can surface created bots on the
/// next refresh (deterministic create-visible flow).
final class ScriptedBotProfileSeamStore: @unchecked Sendable {
    static let shared = ScriptedBotProfileSeamStore()
    private let lock = NSLock()
    private var created: [GatewayID: [ProfileDescriptor]] = [:]

    func record(gatewayID: GatewayID, name: String, title: String?) {
        lock.lock(); defer { lock.unlock() }
        var list = created[gatewayID] ?? []
        guard !list.contains(where: { $0.name == name }) else { return }
        list.append(ProfileDescriptor(
            name: name,
            path: "~/.hermes/profiles/\(name)",
            isDefault: false,
            displayName: title ?? name))
        created[gatewayID] = list
    }

    func createdDescriptors(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return created[gatewayID] ?? []
    }
}

/// True Bots Mode slice 2: scripted bot-profile management seam (DEBUG
/// simulator only) — in-memory metadata/section/avatar state with the same
/// semantics as the real client (CAS conflict on stale revision, model
/// confirmation knob, partial-success outcomes). Presentation data only.
final class ScriptedBotProfileSeam: BotProfileManaging, BotSectionRegistryLoading, BotSectionRegistryWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let gatewayID: GatewayID
    private var metadataByProfile: [String: BotModeMetadata] = [:]
    private var revisionByProfile: [String: Int] = [:]
    private var sections: [BotSection] = []
    private var sectionsRevision = 0

    /// Env knob: `HERMES_FLEET_MODEL_CONFIRM=1` forces the model
    /// confirmation handshake on every model write.
    private var modelConfirmForced: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_MODEL_CONFIRM"] == "1"
    }

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        if gatewayID.rawValue == "workstation" {
            sections = [
                BotSection(id: "sec-script-1", name: "Clients"),
                BotSection(id: "sec-script-2", name: "Research"),
            ]
            sectionsRevision = 1
            var researcher = BotModeMetadata()
            researcher.title = "Researcher"
            researcher.sectionID = "sec-script-2"
            metadataByProfile["researcher"] = researcher
            revisionByProfile["researcher"] = 2
        }
    }

    func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        BotProfileDescription(
            name: profile,
            descriptionText: metadataByProfile[profile]?.descriptionText,
            soul: "Scripted SOUL for \(profile).",
            defaultModel: "hermes",
            provider: "nous",
            skills: [
                .init(name: "code", enabled: true),
                .init(name: "web", enabled: false),
            ],
            toolsets: [.init(name: "fs", label: "Files", toolCount: 4, enabled: true)],
            mcpServers: [.init(name: "script-srv", enabled: true, transport: "http")]
        )
    }

    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
        try await configureProfile(profile, edit: edit, confirmExpensiveModel: false)
    }

    func configureProfile(
        _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        var applied: [String: Bool] = [:]
        if let metadata = edit.metadata {
            let expected = edit.metadataExpectedRevision
            let current: Int
            let appliedMeta: Bool
            (current, appliedMeta) = applyMetadata(profile, metadata: metadata, expected: expected)
            if !appliedMeta {
                throw BotSectionSyncError.conflict(
                    "expected revision \(expected ?? 0) but the gateway has \(current)")
            }
            applied["ui_meta"] = true
        }
        if edit.soul != nil { applied["soul"] = true }
        if edit.descriptionText != nil { applied["description"] = true }
        if edit.hasModelSection {
            if modelConfirmForced && !confirmExpensiveModel {
                return BotProfileEditOutcome(
                    appliedSections: [], failedSections: [],
                    confirmRequired: true,
                    confirmMessage: "Scripted expensive-model confirmation")
            }
            applied["model"] = true
        }
        if edit.disabledSkills != nil { applied["skills"] = true }
        if edit.enabledToolsets != nil { applied["toolsets"] = true }
        if edit.enabledMCPServers != nil { applied["mcp_servers"] = true }
        return BotProfileEditOutcome(edit: edit, applied: applied)
    }

    func createProfile(_ spec: BotCreateSpec) async throws -> String {
        seedProfile(spec.name, metadata: BotModeMetadata(
            title: spec.title, descriptionText: spec.descriptionText))
        return spec.name
    }

    func uploadAvatar(_ profile: String, dataURL: String) async throws {}

    func clearAvatar(_ profile: String) async throws {}

    func avatarData(_ profile: String) async throws -> Data? { nil }

    func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?) {
        currentSections()
    }

    func writeSectionRegistry(
        value: MetadataValue, expectedRevision: Int?
    ) async throws -> MetadataWriteReceiptLike {
        let result = applySections(value, expectedRevision: expectedRevision)
        guard result.applied else {
            throw BotSectionSyncError.conflict(
                "expected revision \(expectedRevision ?? 0) but the gateway has \(result.currentRevision)")
        }
        return MetadataWriteReceiptLike(
            applied: true,
            newRevisions: [BotSectionRegistry.metaKey: result.newRevision])
    }

    // Sync lock helpers (NSLock is unavailable from async contexts).

    /// CAS-apply bot metadata; returns (currentRevision, applied).
    private func applyMetadata(
        _ profile: String, metadata: BotModeMetadata, expected: Int?
    ) -> (Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        let current = revisionByProfile[profile] ?? 0
        if let expected, expected != current {
            return (current, false)
        }
        metadataByProfile[profile] = metadata
        revisionByProfile[profile] = current + 1
        return (current + 1, true)
    }

    private func seedProfile(_ profile: String, metadata: BotModeMetadata) {
        lock.lock(); defer { lock.unlock() }
        metadataByProfile[profile] = metadata
        revisionByProfile[profile] = 1
        ScriptedBotProfileSeamStore.shared.record(gatewayID: gatewayID, name: profile, title: metadata.title)
    }

    private func currentSections() -> (sections: [BotSection], revision: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (sections, sectionsRevision)
    }

    /// CAS-apply the section registry; returns (applied, current, new).
    private func applySections(
        _ value: MetadataValue, expectedRevision: Int?
    ) -> (applied: Bool, currentRevision: Int, newRevision: Int) {
        lock.lock(); defer { lock.unlock() }
        if let expected = expectedRevision, expected != sectionsRevision {
            return (false, sectionsRevision, sectionsRevision)
        }
        sections = BotSectionRegistry.normalize(value)
        sectionsRevision += 1
        return (true, sectionsRevision, sectionsRevision)
    }
}

/// Slice 2: scripted room source — one hosted room + one legacy room on the
/// workstation fixture so both provenances render with distinct identities.
struct ScriptedRoomSource: FleetRoomSourceProviding {
    let gatewayID: GatewayID

    func rooms() async -> [FleetRoom] {
        guard gatewayID.rawValue == "workstation" else { return [] }
        return [
            FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: "room-alpha"),
                name: "Launch Crew",
                members: [
                    FleetRoomMember(name: "Researcher", handle: "researcher"),
                    FleetRoomMember(name: "Default", handle: "default"),
                ],
                recentLog: [
                    FleetRoomMessage(
                        id: "m1",
                        from: .init(kind: .member, name: "Researcher"),
                        text: "Draft is ready for review.",
                        at: 1_757_200_000),
                ],
                hosted: HostedRoomState(
                    authorityGatewayID: gatewayID.rawValue,
                    authorityEpoch: 1,
                    advertisedMethods: ["groups.send", "groups.stop", "groups.log"],
                    driverAvailable: true)
            ),
            FleetRoom(
                id: FleetRoomID(provenance: .desktopLegacy, gatewayID: gatewayID, key: "name:Research Crew"),
                name: "Research Crew",
                members: [FleetRoomMember(name: "Researcher")],
                recentLog: [
                    FleetRoomMessage(
                        id: "l1",
                        from: .init(kind: .member, name: "Researcher"),
                        text: "Older room managed from Desktop.",
                        at: 1_757_100_000_000),
                ]
            ),
        ]
    }
}

#endif
