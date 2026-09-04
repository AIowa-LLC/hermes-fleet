import Foundation
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
            health: health,
            seedRegistrations: FleetServiceGraph.zeroGatewaysEnabled ? [] : ScriptedFleet.registrations
        )
    }
}

/// t_3b321b7b — scripted kanban board watcher (DEBUG simulator only): a
/// small static board with a self-updating event stream so the read-only
/// board view is walkable without a live gateway. Presentation data only.
private final class ScriptedKanbanWatcher: KanbanBoardWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
    /// UI-test knob: `HERMES_FLEET_KANBAN_LIVE_UPDATES=1` enables the scripted
    /// live-update ticker (default off — deterministic walkthroughs).
    private let liveUpdatesEnabled =
        ProcessInfo.processInfo.environment["HERMES_FLEET_KANBAN_LIVE_UPDATES"] == "1"

    func snapshot() async throws -> KanbanBoardSnapshot {
        KanbanBoardSnapshot(
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

/// R9-T5/T6: scripted management seam (DEBUG simulator only) — fixture
/// cron jobs + skills catalog with in-memory mutations so both panes are
/// fully walkable without a live gateway. Presentation data only.
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
        unlocked { jobs }
    }

    func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
        let job = CronJob(
            jobID: "script-cron-\(UUID().uuidString.prefix(6))",
            name: draft.name, schedule: draft.schedule,
            nextRunAt: "2026-09-05T07:00:00", isEnabled: true, state: "enabled",
            promptPreview: String(draft.prompt.prefix(80)))
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

    init(gatewayID: GatewayID) {}

    func learningGraph(profile: String?) async throws -> LearningGraph {
        Self.fixtureGraph()
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
        let isMemory = id.hasPrefix("memory:")
        return LearningNodeDetail(
            id: id,
            kind: isMemory ? "memory" : "skill",
            label: id,
            content: isMemory
                ? "# apple-dev profile memory\n\nVerified Xcode/Swift/repo/toolchain lessons only, no secrets.\n\n(fixture memory chunk for the simulator walkthrough)"
                : "---\nname: \(id)\ndescription: Fixture skill for the simulator walkthrough.\n---\n\n(fixture SKILL.md body)")
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

/// Scripted per-gateway conversation session (DEBUG only): a scripted
/// connection + a scripted conversation client that streams a canned turn
/// (message.start → deltas → message.complete) after each prompt.submit, a
/// no-op replay (nothing to replay), and scripted history. Makes the U3
/// Conversation canvas fully walkable in the simulator without a live gateway.
private struct ScriptedConversationSession: ConversationSessionProviding, ApprovalsCapable, ConversationToolingCapable {
    let gatewayID: GatewayID
    private let client: ScriptedConversationClient
    /// R9-T1: scripted approvals seam (records respond/yolo calls so the
    /// approval banner is fully walkable in the simulator + UI tests).
    let approvalsBox = ScriptedApprovalsBox()
    /// R9-T2/T3/T4: scripted tooling seam (fixture models + usage +
    /// steer/title/branch recorders).
    let toolingBox = ScriptedToolingBox()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        self.client = ScriptedConversationClient(gatewayID: gatewayID)
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
        ConversationSession(
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
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "You said: ", rendered: nil))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: text, rendered: nil))
            streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
            streamBox.yield(.messageComplete(
                sessionID: sessionID,
                text: "Hello from the scripted fleet. You said: \(text)",
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

/// Scripted read-only history (DEBUG only) — an empty transcript is fine for
/// the simulator walkthrough.
private struct ScriptedHistory: SessionHistoryProviding {
    let gatewayID: GatewayID
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        SessionHistory(sessionID: sessionID, count: 0, messages: [])
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
            id: GatewayID(rawValue: "<dev-workstation>"),
            displayName: "MacBook M5",
            endpoint: URL(string: "http://127.0.0.1:8642")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "gaming-4090"),
            displayName: "Gaming 4090",
            endpoint: URL(string: "http://127.0.0.1:9900")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "arch"),
            displayName: "Arch Lab",
            endpoint: URL(string: "http://127.0.0.1:9910")!
        ),
    ]

    static func profiles(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        switch gatewayID.rawValue {
        case "<dev-workstation>":
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
            ]
        case "gaming-4090":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 10, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
            ]
        default:
            return []
        }
    }

    static func sessions(on route: Route) -> [SessionSummary] {
        switch route.gatewayID.rawValue {
        case "<dev-workstation>":
            return [
                ScriptedFleet.session(on: "default"),
                SessionSummary(
                    id: "<dev-workstation>.default.s2", title: "Replay plan review",
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
            id: "<dev-workstation>.\(slug).s1", title: "Fleet setup",
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

#endif
