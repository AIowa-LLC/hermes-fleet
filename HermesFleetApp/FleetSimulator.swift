import Foundation
import os
import UIKit
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

        let environment = AppEnvironment(
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
            cronDashboardFactory: { gateway in
                ScriptedCronDashboard(gatewayID: gateway.id)
            },
            // Card D: scripted artifact transport — deterministic image bytes
            // for any media-root path, plus env knobs for the honest
            // expired/denied states (see ScriptedArtifactRetriever).
            artifactRetrievalFactory: { gateway in
                ScriptedArtifactRetriever(gatewayID: gateway.id)
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
            // Slice 4: interactive room engine (durable log, send/rename/
            // disband/stop/retry/approve counters) — DEBUG simulator only.
            roomCommandFactory: { gateway in
                ScriptedRoomEngine.shared
            },
            roomDriverStatusFactory: { gateway in
                ScriptedRoomEngine.shared
            },
            // Slice 5 (D19): scripted RoomLink engine — env-knobbed:
            // HERMES_FLEET_ROOMLINK=unsupported renders the honest
            // unsupported state; default is a supported direct/TLS catalog.
            roomLinkFactory: { gateway in
                ScriptedRoomLinkEngine(gatewayID: gateway.id)
            },
            health: health,
            seedRegistrations: FleetServiceGraph.zeroGatewaysEnabled
                ? []
                : (FleetServiceGraph.singleGatewayEnabled
                    ? [ScriptedFleet.registrations[0]]
                    : ScriptedFleet.registrations),
            // R10-T4: scripted voice seam (env-knobbed) so the mic button,
            // authorization gate and transcript review are walkable
            // deterministically in the simulator + UI tests — no live speech.
            voiceEngineFactory: { ScriptedVoiceEngine.shared }
        )
        // Card D: `HERMES_FLEET_ARTIFACT_FIXTURE=1` seeds a deterministic
        // observed-artifact library (gateway + source conversation) so the
        // Artifacts destination is walkable without a live generation.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_ARTIFACT_FIXTURE"] == "1" {
            let gatewayID = ScriptedFleet.registrations[0].id ?? GatewayID(rawValue: "workstation")
            environment.recordObservedArtifact(
                ArtifactReference(
                    gatewayID: gatewayID,
                    sessionID: "workstation.default.s1",
                    profile: "default",
                    path: "/home/u/.hermes/cache/images/fixture_briefing_chart.png"),
                sourceTitle: "Fleet morning briefing",
                sourceSubtitle: "default")
            environment.recordObservedArtifact(
                ArtifactReference(
                    gatewayID: gatewayID,
                    sessionID: "workstation.default.s1",
                    profile: "default",
                    path: "/home/u/.hermes/cache/images/fixture_ui_mock.png"),
                sourceTitle: "Fleet morning briefing",
                sourceSubtitle: "default")
        }
        return environment
    }
}

/// Card D — scripted artifact retriever (DEBUG simulator only): deterministic
/// image bytes for any media-root path, so inline generation media and the
/// Artifacts destination are fully walkable without a live gateway.
///
/// Env knobs (the honest failure states):
/// - `HERMES_FLEET_ARTIFACT_EXPIRED=1` → every retrieval reports `.expired`
///   (the gateway no longer serves the path — terminal, never retried);
/// - `HERMES_FLEET_ARTIFACT_DENIED=1` → `.notPermitted` (403-class refusal).
final class ScriptedArtifactRetriever: ArtifactRetrieving, @unchecked Sendable {
    let gatewayID: GatewayID

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact {
        if ProcessInfo.processInfo.environment["HERMES_FLEET_ARTIFACT_EXPIRED"] == "1" {
            throw ArtifactTransportError.expired(detail: "fixture: cache entry aged out")
        }
        if ProcessInfo.processInfo.environment["HERMES_FLEET_ARTIFACT_DENIED"] == "1" {
            throw ArtifactTransportError.notPermitted(detail: "fixture: outside the media roots")
        }
        guard reference.gatewayID == gatewayID else {
            throw ArtifactTransportError.gatewayMismatch(expected: gatewayID, actual: reference.gatewayID)
        }
        return RetrievedArtifact(
            reference: reference,
            data: Self.fixturePNG(for: reference.name),
            mimeType: "image/png")
    }

    /// Deterministic per-artifact gradient PNG (visually distinct rows).
    static func fixturePNG(for name: String) -> Data {
        let size = CGSize(width: 240, height: 150)
        var seed = 0
        for scalar in name.unicodeScalars {
            seed = (seed &* 31 &+ Int(scalar.value)) & 0xFFFFFF
        }
        let hue = Double(seed % 360) / 360.0
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                    saturation: 0.5, brightness: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4))
        }
        return image.pngData() ?? Data()
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
private final class ScriptedKanbanWatcher: KanbanBoardOperating, @unchecked Sendable {
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
        snapshotFromState()
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

    // MARK: Build 41 — scripted mutations (in-memory board state)

    /// Mutable scripted board state (create/move/comment/link/etc).
    private var tasks: [String: (title: String, status: String, assignee: String?, priority: Int)] = [
        "t_script01": ("Scripted: port kanban stream client", "todo", "apple-dev", 2),
        "t_script02": ("Scripted: read-only board view", "todo", "apple-design", 1),
        "t_script03": ("Scripted: live reconnect coverage", "running", "apple-qa", 3),
        "t_script04": ("Scripted: design review pass", "review", "apple-design", 2),
        "t_script05": ("Scripted: domain models", "done", "apple-dev", 1),
    ]
    private var comments: [String: [KanbanComment]] = [:]
    private var links: [String: KanbanTaskLinks] = [:]
    private var scriptedEvents: [KanbanTaskEventRecord] = []
    private var nextEventID = 200
    private var orchestration = KanbanOrchestrationSettings(
        orchestratorProfile: "apple-dev", defaultAssignee: "apple-dev",
        autoDecompose: true, autoPromoteChildren: true,
        resolvedOrchestratorProfile: "apple-dev", resolvedDefaultAssignee: "apple-dev",
        activeProfile: "apple-dev")

    private func recordEvent(_ taskID: String, _ kind: String) {
        nextEventID += 1
        scriptedEvents.append(KanbanTaskEventRecord(
            id: nextEventID, taskID: taskID, runID: nil, kind: kind, createdAt: Date().timeIntervalSince1970))
    }

    private func notifyChange(_ taskID: String, _ kind: String) {
        recordEvent(taskID, kind)
        let batch = KanbanEventBatch(
            events: [KanbanChangeEvent(id: nextEventID, taskID: taskID, kind: kind, createdAt: nil)],
            cursor: nextEventID)
        let targets = unlocked { Array(continuations.values) }
        for target in targets { target.yield(batch) }
    }

    private func snapshotFromState() -> KanbanBoardSnapshot {
        let board = unlocked { pinned }
        var byColumn: [String: [KanbanCard]] = [:]
        if board == "side-quests" {
            byColumn["todo"] = [
                KanbanCard(id: "t_side01", title: "Scripted: side quest one", status: "todo", assignee: "apple-dev", priority: 1, createdAt: 1_780_003_600, latestSummary: nil),
            ]
            byColumn["done"] = [
                KanbanCard(id: "t_side02", title: "Scripted: side quest two", status: "done", assignee: "apple-design", priority: 1, createdAt: 1_779_996_400, latestSummary: nil),
            ]
            return KanbanBoardSnapshot(columns: ["todo", "done"], cardsByColumn: byColumn, latestEventID: 2, now: 1_780_014_400)
        }
        let order = ["triage", "todo", "ready", "running", "blocked", "review", "done"]
        for column in order { byColumn[column] = [] }
        for (id, task) in tasks.sorted(by: { $0.value.priority > $1.value.priority }) {
            let column = order.contains(task.status) ? task.status : "todo"
            byColumn[column]?.append(KanbanCard(
                id: id, title: task.title, status: task.status, assignee: task.assignee,
                priority: task.priority, createdAt: 1_780_000_000, latestSummary: nil))
        }
        return KanbanBoardSnapshot(columns: order, cardsByColumn: byColumn, latestEventID: nextEventID, now: Date().timeIntervalSince1970)
    }

    func snapshot(includeArchived: Bool) async throws -> KanbanBoardSnapshot {
        var snapshot = snapshotFromState()
        if includeArchived {
            snapshot = KanbanBoardSnapshot(
                columns: snapshot.columns + ["archived"],
                cardsByColumn: snapshot.cardsByColumn,
                latestEventID: snapshot.latestEventID, now: snapshot.now)
        }
        return snapshot
    }

    func createTask(_ draft: KanbanTaskDraft) async throws -> KanbanCard {
        let id = "t_script\(String(format: "%02d", tasks.count + 1))"
        let status = draft.triage ? "triage" : "todo"
        tasks[id] = (draft.title, status, draft.assignee, draft.priority)
        for parent in draft.parents {
            var parentLinks = links[parent] ?? KanbanTaskLinks(parents: [], children: [])
            parentLinks = KanbanTaskLinks(
                parents: parentLinks.parents, children: parentLinks.children + [id])
            links[parent] = parentLinks
        }
        notifyChange(id, "created")
        return KanbanCard(id: id, title: draft.title, status: status, assignee: draft.assignee, priority: draft.priority, createdAt: Date().timeIntervalSince1970, latestSummary: nil)
    }

    func updateTask(id: String, patch: KanbanTaskPatch) async throws -> KanbanCard {
        guard tasks[id] != nil else { throw KanbanMutationError.rejected("task \(id) not found") }
        if let status = patch.status {
            if status == "running" {
                throw KanbanMutationError.rejected("Cannot set status to 'running' directly; use the dispatcher/claim path")
            }
            tasks[id]?.status = status == "archived" ? "archived" : status
            notifyChange(id, "status_changed")
        }
        if let assignee = patch.assignee {
            tasks[id]?.assignee = assignee.isEmpty ? nil : assignee
            notifyChange(id, "assigned")
        }
        if let priority = patch.priority {
            tasks[id]?.priority = priority
            notifyChange(id, "reprioritized")
        }
        if let title = patch.title { tasks[id]?.title = title; notifyChange(id, "edited") }
        if let body = patch.body { _ = body; notifyChange(id, "edited") }
        let task = tasks[id]!
        return KanbanCard(id: id, title: task.title, status: task.status, assignee: task.assignee, priority: task.priority, createdAt: 1_780_000_000, latestSummary: nil)
    }

    func deleteTask(id: String) async throws {
        tasks.removeValue(forKey: id)
        notifyChange(id, "deleted")
    }

    func fetchTaskDetail(id: String) async throws -> KanbanTaskDetail {
        guard let task = tasks[id] else { throw KanbanMutationError.rejected("task \(id) not found") }
        let taskLinks = links[id] ?? KanbanTaskLinks(parents: [], children: [])
        let children = taskLinks.children.compactMap { childID -> KanbanChildResult? in
            guard let child = tasks[childID] else { return nil }
            return KanbanChildResult(id: childID, title: child.title, status: child.status, latestSummary: nil, result: nil)
        }
        return KanbanTaskDetail(
            task: KanbanTaskRecord(
                id: id, title: task.title, body: "Scripted task body for the walkthrough.",
                assignee: task.assignee, status: task.status, priority: task.priority,
                createdAt: 1_780_000_000, workspaceKind: "scratch"),
            comments: comments[id] ?? [],
            events: scriptedEvents.filter { $0.taskID == id }.suffix(10).map { $0 },
            links: taskLinks,
            childResults: children,
            runs: [])
    }

    func addComment(taskID: String, body: String, author: String?) async throws {
        guard tasks[taskID] != nil else { throw KanbanMutationError.rejected("task \(taskID) not found") }
        var list = comments[taskID] ?? []
        list.append(KanbanComment(id: list.count + 1, taskID: taskID, author: author ?? "dashboard", body: body, createdAt: Date().timeIntervalSince1970))
        comments[taskID] = list
        notifyChange(taskID, "commented")
    }

    func linkTasks(parentID: String, childID: String) async throws -> Bool {
        guard tasks[parentID] != nil, tasks[childID] != nil else {
            throw KanbanMutationError.rejected("unknown task id")
        }
        var parentLinks = links[parentID] ?? KanbanTaskLinks(parents: [], children: [])
        parentLinks = KanbanTaskLinks(parents: parentLinks.parents, children: parentLinks.children + [childID])
        links[parentID] = parentLinks
        notifyChange(childID, "linked")
        return true
    }

    func unlinkTasks(parentID: String, childID: String) async throws {
        var parentLinks = links[parentID] ?? KanbanTaskLinks(parents: [], children: [])
        parentLinks = KanbanTaskLinks(parents: parentLinks.parents, children: parentLinks.children.filter { $0 != childID })
        links[parentID] = parentLinks
        notifyChange(childID, "unlinked")
        return
    }

    func bulkUpdate(_ patch: KanbanBulkPatch) async throws -> [KanbanBulkOutcome] {
        var outcomes: [KanbanBulkOutcome] = []
        for id in patch.ids {
            do {
                try await updateTask(id: id, patch: KanbanTaskPatch(
                    status: patch.status, assignee: patch.assignee, priority: patch.priority))
                outcomes.append(KanbanBulkOutcome(id: id, ok: true))
            } catch {
                outcomes.append(KanbanBulkOutcome(
                    id: id, ok: false, error: Redaction.safeErrorDescription(error)))
            }
        }
        return outcomes
    }

    func reclaimTask(id: String, reason: String?) async throws {
        guard tasks[id] != nil else { throw KanbanMutationError.rejected("task \(id) not found") }
        if tasks[id]?.status != "running" {
            throw KanbanMutationError.rejected("cannot reclaim \(id): not in a claimable state (not running, or unknown id)")
        }
        tasks[id]?.status = "ready"
        notifyChange(id, "reclaimed")
    }

    func specifyTask(id: String, author: String?) async throws -> KanbanSpecifyOutcome {
        guard tasks[id] != nil else { throw KanbanMutationError.rejected("task \(id) not found") }
        recordEvent(id, "specified")
        return KanbanSpecifyOutcome(ok: true, taskID: id, reason: nil, newTitle: tasks[id]?.title)
    }

    func decomposeTask(id: String, author: String?) async throws -> KanbanDecomposeOutcome {
        guard let task = tasks[id] else { throw KanbanMutationError.rejected("task \(id) not found") }
        let child1 = "t_dec\(nextEventID)a"
        let child2 = "t_dec\(nextEventID)b"
        tasks[child1] = ("\(task.title) — part 1", "todo", task.assignee, task.priority)
        tasks[child2] = ("\(task.title) — part 2", "todo", task.assignee, task.priority)
        var taskLinks = links[id] ?? KanbanTaskLinks(parents: [], children: [])
        taskLinks = KanbanTaskLinks(parents: taskLinks.parents, children: taskLinks.children + [child1, child2])
        links[id] = taskLinks
        notifyChange(id, "decomposed")
        return KanbanDecomposeOutcome(ok: true, taskID: id, reason: nil, fanout: true, childIDs: [child1, child2], newTitle: task.title)
    }

    func reassignTask(id: String, profile: String?, reclaimFirst: Bool, reason: String?) async throws {
        guard tasks[id] != nil else { throw KanbanMutationError.rejected("task \(id) not found") }
        if reclaimFirst, tasks[id]?.status == "running" {
            tasks[id]?.status = "ready"
        }
        tasks[id]?.assignee = profile
        notifyChange(id, "reassigned")
    }

    func fetchAssignees() async throws -> [String] {
        ["apple-dev", "apple-design", "apple-qa", "default"]
    }

    func orchestrationSettings() async throws -> KanbanOrchestrationSettings {
        unlocked { orchestration }
    }

    func updateOrchestrationSettings(_ patch: KanbanOrchestrationPatch) async throws -> KanbanOrchestrationSettings {
        unlocked {
            if let p = patch.orchestratorProfile {
                orchestration = KanbanOrchestrationSettings(
                    orchestratorProfile: p,
                    defaultAssignee: orchestration.defaultAssignee,
                    autoDecompose: orchestration.autoDecompose,
                    autoPromoteChildren: orchestration.autoPromoteChildren,
                    resolvedOrchestratorProfile: p,
                    resolvedDefaultAssignee: orchestration.resolvedDefaultAssignee,
                    activeProfile: orchestration.activeProfile)
            }
            if let d = patch.defaultAssignee {
                orchestration = KanbanOrchestrationSettings(
                    orchestratorProfile: orchestration.orchestratorProfile,
                    defaultAssignee: d,
                    autoDecompose: orchestration.autoDecompose,
                    autoPromoteChildren: orchestration.autoPromoteChildren,
                    resolvedOrchestratorProfile: orchestration.resolvedOrchestratorProfile,
                    resolvedDefaultAssignee: d,
                    activeProfile: orchestration.activeProfile)
            }
            return orchestration
        }
    }

    func dispatchNudge(dryRun: Bool, max: Int) async throws -> KanbanDispatchResult {
        var spawned: [KanbanDispatchResult.Spawned] = []
        if !dryRun {
            for (id, task) in tasks where task.status == "ready" {
                tasks[id]?.status = "running"
                spawned.append(KanbanDispatchResult.Spawned(taskID: id, assignee: task.assignee ?? "default", workspacePath: "/tmp/kanban-\(id)"))
                notifyChange(id, "claimed")
            }
        }
        return KanbanDispatchResult(
            reclaimed: 0, promoted: 0, spawned: spawned,
            skippedUnassigned: [], skippedPerProfileCapped: [],
            crashed: [], autoBlocked: [], timedOut: [], stale: [],
            rateLimited: [], skippedLocked: false, memoryPressure: nil)
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
///
/// UI-test knob: `HERMES_FLEET_SESSIONS_FAIL=<gateway-id>[,<gateway-id>…]`
/// makes the read FAIL for the listed gateways (a classified `RosterError`),
/// so the Chats refresh-failure surfaces (dogfood finding 1) are reachable in
/// a deterministic UI test — one gateway fails while another still holds
/// usable sessions (the compact inline surface).
private struct ScriptedSessionListService: SessionListProviding {
    static var failingGatewayIDs: Set<String> {
        let raw = ProcessInfo.processInfo.environment["HERMES_FLEET_SESSIONS_FAIL"] ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        if Self.failingGatewayIDs.contains(route.gatewayID.rawValue) {
            throw RosterError.notConnected
        }
        return ScriptedFleet.sessions(on: route)
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
        // The scripted gateway supports run by default (R9-era fixture
        // behavior the general Cron pane's regression test relies on —
        // a gateway that DOES forward cron.manage run). The launch arg
        // `-fixture-run-now-fails` scripts the REAL 0.21.0 wire answer
        // (methods_tools.py:1033-1057: run not forwarded → err 4016) so
        // the honest unsupported-explanation path is UI-testable against
        // the same shape the live gateway returns.
        if ProcessInfo.processInfo.arguments.contains("-fixture-run-now-fails") {
            throw GatewayManagementError.unsupportedAction("unknown cron action: run")
        }
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
private struct ScriptedConversationSession: ConversationSessionProviding, ApprovalsCapable, ConversationToolingCapable, AttachmentStagingCapable, ReactionCapable, SlashCommandCapable, ReasoningCapable {
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
    /// Issue #4: scripted Hermes skill discovery/completion/dispatch so the
    /// slash palette is walkable in simulator UI tests without a gateway.
    let slashCommandsBox: ScriptedSlashCommandBox
    /// Dogfood r8: scripted reasoning seam (serves config.get, records
    /// config.set calls + a scriptable starting level so the thinking
    /// slider is fully walkable in the simulator + UI tests).
    let reasoningBox = ScriptedReasoningBox()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        self.client = ScriptedConversationClient(gatewayID: gatewayID)
        self.slashCommandsBox = ScriptedSlashCommandBox(gatewayID: gatewayID)
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

    /// Dogfood r8: scripted reasoning seam.
    var reasoning: any ReasoningProviding {
        reasoningBox
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

    var slashCommands: any SlashCommandProviding {
        slashCommandsBox
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

/// Slash-command parity scripted capability: models the real Hermes wire
/// shapes (commands.catalog / complete.slash / command.dispatch / slash.exec
/// / process.stop) so the composer palette and command routing are walkable
/// in simulator UI tests without a gateway.
///
/// Fixtures (DEBUG simulator builds, selected by the existing scripted
/// route/session combinations): workstation/default/s2 has an empty catalog,
/// workstation/researcher/s1 fails discovery, and render-box models a stale
/// dispatch. The normal workstation/default/s1 conversation carries the full
/// parity fixture set: /new, /reset (alias), /steer, /stop, /title, /branch,
/// /fork (alias), /status, /help, one exec command, one prefill command, one
/// installed skill, one dynamic quick/extension command, one terminal-only
/// (unavailable) command, and one unknown-dispatch command.
private final class ScriptedSlashCommandBox: SlashCommandProviding, @unchecked Sendable {
    private enum FixtureMode: Equatable {
        case normal
        case emptyCatalog
        case discoveryFailure
        case staleDispatch
    }

    /// Mirrors the real 0.21.3 catalog shape: registry built-ins carry
    /// argument modes + desktop dispositions; quick/plugin commands ride
    /// `pairs` without `commands` meta; skills carry usage/origin.
    private let catalogRows: [SlashCommandSuggestion] = [
        SlashCommandSuggestion(
            text: "/new",
            description: "Start a new session (fresh session ID + history)",
            kind: .command,
            argumentMode: .text),
        SlashCommandSuggestion(
            text: "/steer",
            description: "Inject a message after the next tool call without interrupting",
            kind: .command,
            argumentMode: .text),
        SlashCommandSuggestion(
            text: "/stop",
            description: "Kill all running background processes",
            kind: .command),
        SlashCommandSuggestion(
            text: "/title",
            description: "Set a title for the current session",
            kind: .command,
            argumentMode: .text),
        SlashCommandSuggestion(
            text: "/branch",
            description: "Branch the current session (explore a different path)",
            kind: .command,
            argumentMode: .text),
        SlashCommandSuggestion(
            text: "/status",
            description: "Show session, model, token, and context info",
            kind: .command),
        SlashCommandSuggestion(
            text: "/help",
            description: "Show available commands",
            kind: .command),
        SlashCommandSuggestion(
            text: "/model",
            description: "Switch model (session-scoped)",
            kind: .command,
            desktopDisposition: "hidden"),
        SlashCommandSuggestion(
            text: "/resume",
            description: "Resume a previously-named session",
            kind: .command,
            argumentMode: .mixed),
        // Exec-style backend command (plain worker output).
        SlashCommandSuggestion(
            text: "/usage",
            description: "Show token usage and rate limits",
            kind: .command),
        // Prefill-style backend command (/undo returns a prefill directive).
        SlashCommandSuggestion(
            text: "/undo",
            description: "Back up N user turns and re-prompt (default 1)",
            kind: .command),
        // Terminal-only: present in the catalog but never suggested on iOS.
        SlashCommandSuggestion(
            text: "/redraw",
            description: "Force a full UI repaint (recovers from terminal drift)",
            kind: .command,
            desktopDisposition: "terminal"),
        // Dynamic extension (quick command): no registry meta.
        SlashCommandSuggestion(
            text: "/deploy-check",
            description: "exec: fleet-status --canary",
            kind: .extensionCommand),
        // Unknown-dispatch probe: backend-owned, returns a future type.
        SlashCommandSuggestion(
            text: "/future-probe",
            description: "Returns a dispatch Fleet does not know",
            kind: .command),
        // Installed skills (usage-ranked in the fixture).
        SlashCommandSuggestion(
            text: "/hermes-change-review",
            description: "Review a change against its issue",
            kind: .skill,
            usage: 4),
        SlashCommandSuggestion(
            text: "/hermes-plan",
            description: "Build an implementation plan",
            kind: .skill,
            usage: 0),
    ]

    /// The canon map: aliases → canonical (mirrors `canon` on the wire).
    private let canon: [String: String] = [
        "/reset": "/new",
        "/fork": "/branch",
    ]

    private let gatewayID: GatewayID

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    /// Keep failure fixtures tied to existing scripted session rows so the
    /// UI tests do not depend on process-launch configuration. The normal
    /// workstation/default/s1 conversation remains the happy-path fixture.
    private func mode(for sessionID: String?) -> FixtureMode {
        if gatewayID.rawValue == "render-box" {
            return .staleDispatch
        }
        switch sessionID {
        case "workstation.default.s2":
            return .emptyCatalog
        case "workstation.researcher.s1":
            return .discoveryFailure
        default:
            return .normal
        }
    }

    private func catalogPayload(sessionID: String?) throws -> HermesCommandCatalog {
        switch mode(for: sessionID) {
        case .discoveryFailure:
            throw SlashCommandError.rpcFailed("scripted command discovery failed")
        case .emptyCatalog:
            return HermesCommandCatalog(commands: [], canon: [:], commandMeta: [:], skills: [:])
        case .normal, .staleDispatch:
            var meta: [String: SlashCommandSuggestion] = [:]
            for row in catalogRows where row.desktopDisposition != nil || row.argumentMode != nil {
                meta[row.text.lowercased()] = row
            }
            let skills = Dictionary(
                uniqueKeysWithValues: catalogRows.filter { $0.kind == .skill }.map {
                    ($0.text, HermesCommandCatalog.SkillEntry(usage: $0.usage, origin: "local"))
                })
            return HermesCommandCatalog(
                commands: catalogRows,
                canon: canon,
                commandMeta: meta,
                skills: skills)
        }
    }

    func catalog(sessionID: String?) async throws -> HermesCommandCatalog {
        try catalogPayload(sessionID: sessionID)
    }

    func complete(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] {
        let payload = try catalogPayload(sessionID: sessionID)
        let query = text.drop(while: { $0 == "/" }).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let lowered = query.lowercased()
        return payload.commands.filter { $0.text.dropFirst().lowercased().hasPrefix(lowered) }
    }

    func dispatch(sessionID: String, name: String, argument: String) async throws -> HermesCommandDispatch {
        let canonical = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let lowered = canonical.lowercased()
        if mode(for: sessionID) == .staleDispatch {
            throw SlashCommandError.commandUnavailable(lowered)
        }
        if lowered == "future-probe" {
            throw SlashCommandError.unknownDispatchType("holodeck")
        }
        guard catalogRows.contains(where: { $0.text.dropFirst().lowercased() == lowered }) else {
            throw SlashCommandError.commandUnavailable(lowered)
        }
        if lowered == "undo" {
            return .prefill(message: "Edited follow-up prompt", notice: "Backed up 1 turn")
        }
        let display = argument.isEmpty ? "/" + canonical : "/" + canonical + " " + argument
        return .skill(
            message: "[Scripted expanded skill: \(canonical)]\n\(argument)",
            display: display)
    }

    func execute(sessionID: String, command: String) async throws -> HermesSlashExecution {
        let bare = command.drop(while: { $0 == "/" })
        let parts = bare.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? String(parts[1]) : ""
        let lowered = name.lowercased()
        if mode(for: sessionID) == .staleDispatch {
            throw SlashCommandError.commandUnavailable(lowered)
        }
        if lowered == "future-probe" {
            throw SlashCommandError.unknownDispatchType("holodeck")
        }
        guard catalogRows.contains(where: { $0.text.dropFirst().lowercased() == lowered }) else {
            throw SlashCommandError.commandUnavailable(lowered)
        }
        if lowered == "undo" {
            return HermesSlashExecution(
                output: nil,
                warning: nil,
                dispatch: .prefill(message: "Edited follow-up prompt", notice: "Backed up 1 turn"))
        }
        if lowered == "usage" {
            return HermesSlashExecution(output: "Session tokens: 1,234 input / 567 output", warning: nil)
        }
        let display = argument.isEmpty ? "/" + name : "/" + name + " " + argument
        return HermesSlashExecution(
            output: nil,
            warning: nil,
            dispatch: .skill(
                message: "[Scripted expanded skill: \(name)]\n\(argument)",
                display: display))
    }

    func stopProcesses(sessionID: String) async throws -> Int {
        // Fixture: one background process existed and was killed.
        1
    }
}

/// Scripted `ConversationProviding` that streams a canned turn after submit.
private final class ScriptedConversationClient: ConversationProviding, @unchecked Sendable {
    /// Issue #5 UI fixture: deliberately crosses incomplete bold, list, table,
    /// and fenced-code boundaries while keeping the wire shape as ordinary
    /// message.delta text. It is enabled only by an explicit UI-test launch
    /// argument; the default simulator response remains unchanged for all
    /// existing slash, attachment, reaction, and conversation tests.
    private static let issue5RichMarkdownChunks: [String] = [
        "# Streaming rich text\n\n",
        "Assistant content arrives as **half-finished bold",
        "** and *italic* with ~~strike~~ and `inline code`.\n\n",
        "## Structure\n\n- first list item\n- [",
        "] partial task\n1. ordered item\n2. second",
        " ordered item\n\n> blockquote\n\n---\n\n",
        "### Code\n\n```",
        "swift\nlet answer = \"streaming\"\n",
        "```\n\n### Table\n\n| Feature | State |\n| --- |",
        " --- |\n| Markdown | active |\n\n",
        "[Safe link](https://github.com/AIowa-LLC/hermes-fleet/issues/5)\n\n",
        "![pixel](https://example.invalid/tracker.png)\n",
        "[unsafe](javascript:alert(1))\n\n",
        "<script>alert(\"inert\")</script>\n\n",
        "Malformed **bold and [link"
    ]

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

    func resumeSession(sessionID: String, lastEventID: Int? = nil, profile: String? = nil) async throws -> ConversationSession {
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
            let fixtureBearer = ["fixture", "bearer", "demo"].joined(separator: "-")
            Task { [streamBox, fixtureBearer] in
                try? await Task.sleep(for: .milliseconds(400))
                streamBox.yield(.approvalRequested(
                    sessionID: sessionID,
                    requestID: "scripted-approval-1",
                    // Fixture token is FAKE (demo only) — allowline-annotated
                    // because the redaction path must be exercised with a
                    // token-shaped bearer fixture, even though it is inert.
                    command: "curl -H 'Authorization: Bearer \(fixtureBearer)' https://api.example.invalid",
                    detail: "Scripted credential-bearing command (simulator demo)",
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
            // Card D demo hook (simulator only): `HERMES_FLEET_IMAGE_DEMO=1`
            // makes every scripted turn run an image_generate call whose
            // result names a retrievable gateway path — the inline artifact,
            // the shared retrieval store and the prose echo-strip are then
            // walkable end-to-end without a live gateway. Tools run BEFORE
            // message.start (the real turn order: user → tools → reply).
            let imageDemo = ProcessInfo.processInfo.environment["HERMES_FLEET_IMAGE_DEMO"] == "1"
            // Card E: the two REAL wire shapes of a turn that runs
            // `image_generate`:
            // - default (tools-first): user → tools → reply. The tool frames
            //   (and their result) precede `message.start`; card D's inline
            //   journey pins this layout, and `updateLastTool`'s turn-scoped
            //   geometry requires the result before the assistant row;
            // - `HERMES_FLEET_IMAGE_DEMO_ORDER=streaming`: the turn streams
            //   first (`message.start` …) and the tool runs mid-turn — the
            //   window in which the composer's Stop control exists (the phase
            //   is `.ready` until `message.start`).
            let imageDemoOrderStreaming =
                ProcessInfo.processInfo.environment["HERMES_FLEET_IMAGE_DEMO_ORDER"] == "streaming"

            func emitGenerationStart() {
                // The live wire emits `tool.generating` BEFORE `tool.start`
                // (P0-8 probe seq 66 vs 68) — mirrored exactly.
                streamBox.yield(.toolGenerating(sessionID: sessionID, name: "image_generate"))
                streamBox.yield(.toolStart(
                    sessionID: sessionID, toolID: "t-img-1", name: "image_generate",
                    context: "scripted generation", argsText: nil))
            }

            func emitGenerationCompletion() async {
                // Card E: `HERMES_FLEET_IMAGE_DEMO_HOLD_MS=<n>` keeps the
                // generation IN FLIGHT for n ms (with a named progress frame
                // mid-hold) so the branded animation is observable in UI tests
                // and the manual demo; unset/0 preserves card D's immediate
                // complete flow. `HERMES_FLEET_IMAGE_DEMO_FAIL=1` completes
                // with an explicit failure instead — the stop path.
                let holdMs = Int(ProcessInfo.processInfo.environment["HERMES_FLEET_IMAGE_DEMO_HOLD_MS"] ?? "") ?? 0
                if holdMs > 0 {
                    try? await Task.sleep(for: .milliseconds(holdMs / 2))
                    streamBox.yield(.toolProgress(
                        sessionID: sessionID, toolID: "t-img-1", name: "image_generate",
                        text: "generating (scripted)"))
                    try? await Task.sleep(for: .milliseconds(holdMs / 2))
                }
                let failure = ProcessInfo.processInfo.environment["HERMES_FLEET_IMAGE_DEMO_FAIL"] == "1"
                streamBox.yield(.toolComplete(
                    sessionID: sessionID, toolID: "t-img-1", name: "image_generate",
                    summary: nil,
                    resultText: failure
                        ? #"{"success": false, "error": "scripted generation failure"}"#
                        : #"{"success": true, "image": "/home/u/.hermes/cache/images/scripted_generation.png", "modality": "text", "upscaled": false}"#))
            }

            // Tools-first: BOTH the start and the result precede
            // `message.start` — the shape card D's inline journey pins and the
            // only shape `updateLastTool`'s turn-scoped geometry keeps on one
            // chip.
            if imageDemo && !imageDemoOrderStreaming {
                emitGenerationStart()
                await emitGenerationCompletion()
            }
            streamBox.yield(.messageStart(sessionID: sessionID))
            // Streaming: the turn is already streaming while the tool runs
            // (the composer's Stop control exists in this window).
            if imageDemo && imageDemoOrderStreaming {
                emitGenerationStart()
                await emitGenerationCompletion()
            }
            if ProcessInfo.processInfo.arguments.contains("-issue5-markdown-fixture") {
                // Keep the initial empty assistant row on screen long enough
                // for the UI fixture to verify that the preceding user row
                // remains literal before the rich answer grows past it.
                try? await Task.sleep(for: .milliseconds(1_500))
                var fullMarkdown = ""
                for chunk in Self.issue5RichMarkdownChunks {
                    fullMarkdown += chunk
                    streamBox.yield(.messageDelta(sessionID: sessionID, text: chunk, rendered: nil))
                }
                streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
                streamBox.yield(.messageComplete(
                    sessionID: sessionID,
                    text: fullMarkdown,
                    status: nil,
                    error: nil
                ))
                return
            }
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
            // The dispatch expansion is model-facing scaffolding. Keep the
            // scripted assistant's human-facing echo focused on the user's
            // argument so the simulator proves that expansion never leaks
            // into the transcript UI.
            let visibleEchoSource: String
            if text.hasPrefix("[Scripted expanded skill:"),
               let newline = text.firstIndex(of: "\n") {
                visibleEchoSource = String(text[text.index(after: newline)...])
            } else {
                visibleEchoSource = text
            }
            let echoBase = visibleEchoSource
                .split(whereSeparator: \.isWhitespace)
                .filter { !$0.contains("@file:") && !$0.contains("@folder:") }
                .joined(separator: " ")
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "You said: ", rendered: nil))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: echoBase, rendered: nil))
            streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
            // Top chip bar UI-journey knob: after the turn, emit a
            // session.info carrying cwd + profile_name (the live gateway's
            // end-of-turn shape) so the folder/profile chips are testable.
            if ProcessInfo.processInfo.environment["HERMES_FLEET_SESSION_INFO_FIXTURE"] == "1" {
                // Literal cwd (matches ScriptedToolingBox's default): the
                // client has no tooling-box reference; the r9 folder-switch
                // test drives a change through the sheet and asserts the
                // chip readback before any next-turn fixture fires.
                streamBox.yield(.sessionInfo(
                    sessionID: sessionID,
                    model: "glm-4.6-flash", provider: "zai",
                    title: nil,
                    cwd: "/home/dev/hermes-fleet",
                    profileName: "default"))
            }
            // UI-journey knob (HERMES_FLEET_SESSION_TITLE_FIXTURE=1): mirror
            // the live gateway's auto-title frame (methods_session.py:1427)
            // so the header-adoption path is testable without a gateway.
            if ProcessInfo.processInfo.environment["HERMES_FLEET_SESSION_TITLE_FIXTURE"] == "1" {
                streamBox.yield(.sessionTitleUpdate(
                    sessionID: sessionID,
                    title: "Scripted auto title"))
            }
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

/// Dogfood r8: scripted reasoning seam (DEBUG simulator). Serves the
/// scriptable current level on read, records every set call (thread-safe),
/// and flips the served value so the chip reflects the applied stop without
/// a real gateway. The default served level is the gateway's documented
/// default (`medium`).
final class ScriptedReasoningBox: ReasoningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _level: FleetReasoningLevel = .defaultLevel
    private var _setLevels: [FleetReasoningLevel] = []

    /// The served current level (config.get readback).
    var level: FleetReasoningLevel {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    /// Every setReasoning call in order (UI-test assertion material).
    var setLevels: [FleetReasoningLevel] {
        lock.lock(); defer { lock.unlock() }
        return _setLevels
    }

    /// Scriptable starting level (fixture knob for tests that need a
    /// non-default anchor).
    func seed(_ level: FleetReasoningLevel) {
        lock.lock(); defer { lock.unlock() }
        _level = level
    }

    // Sync-record helpers (NSLock is unavailable from async contexts —
    // the ScriptedApprovalsBox pattern).
    private func syncLevel() -> FleetReasoningLevel {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    private func syncSet(_ level: FleetReasoningLevel) {
        lock.lock(); defer { lock.unlock() }
        _setLevels.append(level)
        _level = level
    }

    func reasoning(sessionID: String) async throws -> ReasoningState {
        let current = syncLevel()
        return ReasoningState(level: current, rawValue: current.rawValue, display: "show")
    }

    func setReasoning(_ level: FleetReasoningLevel, sessionID: String) async throws -> FleetReasoningLevel {
        syncSet(level)
        return level
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
    private var _cwdSets: [String] = []
    /// The cwd the box currently serves (seeded by session-info fixture;
    /// flipped by each setCWD call — the UI test asserts the chip follows).
    private var _servedCWD: String = "/home/dev/hermes-fleet"

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
    var cwdSets: [String] {
        lock.lock(); defer { lock.unlock() }
        return _cwdSets
    }
    var servedCWD: String {
        lock.lock(); defer { lock.unlock() }
        return _servedCWD
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

    /// r9 toolbelt: flip the served cwd + record the write (UI tests assert
    /// the chip's value follows the readback).
    func setCWD(sessionID: String, cwd: String) async throws -> SessionCWDInfo {
        recordCWD(cwd)
        return SessionCWDInfo(cwd: serveCWD(cwd), branch: "main", project: nil)
    }

    private func recordCWD(_ cwd: String) {
        lock.lock(); defer { lock.unlock() }
        _cwdSets.append(cwd)
    }
    private func serveCWD(_ cwd: String) -> String {
        lock.lock(); defer { lock.unlock() }
        _servedCWD = cwd
        return _servedCWD
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
/// Deterministic 8x8 PNG fixtures for the scripted pet surface (#9) —
/// tiny valid PNGs (magenta / solid green) standing in for pet.thumb
/// idle frames. Distinct per gateway to prove route-scoped caching.
enum ScriptedPetPNG {
    static let magenta = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGP4z7DoP8MoQS4BAPMYqAH2vyKxAAAAAElFTkSuQmCC")!
    static let green = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGNgOFHxn2GUIJcAAIjXj8EqoCrvAAAAAElFTkSuQmCC")!
}

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
        // #7: appearance writes (metadata + avatar asset state) through the
        // scripted seam overlay the static descriptors — a roster refresh
        // after an avatar Save reflects gateway-authoritative appearance.
        func overlay(_ descriptor: ProfileDescriptor) -> ProfileDescriptor {
            guard let appearance = ScriptedBotProfileSeamStore.shared.appearanceOverlay(
                on: gatewayID, profile: descriptor.name) else { return descriptor }
            var uiMeta = descriptor.uiMeta ?? [:]
            uiMeta[BotModeContract.botsMetaKey] = .object(appearance.metadata.toWire())
            var revisions = descriptor.uiMetaRevisions ?? MetadataRevisions(revisions: [:])
            revisions.revisions[BotModeContract.botsMetaKey] =
                (revisions.revisions[BotModeContract.botsMetaKey] ?? 0) + 1
            return ProfileDescriptor(
                name: descriptor.name,
                path: descriptor.path,
                isDefault: descriptor.isDefault,
                model: descriptor.model,
                provider: descriptor.provider,
                profileDescription: descriptor.profileDescription,
                displayName: descriptor.displayName,
                skillCount: descriptor.skillCount,
                hasAvatar: appearance.hasAvatar,
                lastSession: descriptor.lastSession,
                gatewayRunning: descriptor.gatewayRunning,
                canonicalSession: descriptor.canonicalSession,
                workerSession: descriptor.workerSession,
                uiMetaRevisions: revisions,
                uiMeta: uiMeta)
        }
        switch gatewayID.rawValue {
        case "workstation":
            return [
                overlay(ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 12, hasAvatar: true,
                    lastSession: ScriptedFleet.session(gateway: gatewayID, slug: "default")
                )),
                overlay(ProfileDescriptor(
                    name: "researcher", path: "~/.hermes/profiles/researcher",
                    isDefault: false, model: "hermes", provider: "openrouter",
                    displayName: "Researcher", skillCount: 8, hasAvatar: true,
                    lastSession: ScriptedFleet.session(gateway: gatewayID, slug: "researcher"),
                    uiMeta: ProcessInfo.processInfo.environment["HERMES_FLEET_HIDDEN_BOT"] == "1"
                        ? [BotModeContract.botsMetaKey: .object(BotModeMetadata(hidden: true).toWire())]
                        : nil
                )),
            ] + created
        case "render-box":
            return [
                overlay(ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 10, hasAvatar: true,
                    lastSession: ScriptedFleet.session(gateway: gatewayID, slug: "default")
                )),
            ] + created
        default:
            return created
        }
    }

    static func sessions(on route: Route) -> [SessionSummary] {
        switch route.gatewayID.rawValue {
        case "workstation":
            if route.profileSlug.rawValue == "researcher" {
                return [
                    SessionSummary(
                        id: "workstation.researcher.s1", title: "Research briefing",
                        preview: "Researcher profile scripted discovery fixture.", startedAt: 1_755_000_000,
                        messageCount: 8, source: "ios"
                    ),
                ]
            }
            return [
                ScriptedFleet.session(gateway: route.gatewayID, slug: "default"),
                SessionSummary(
                    id: "workstation.default.s2", title: "Replay plan review",
                    preview: "Discussing the reconnect/replay design.", startedAt: 1_755_000_000,
                    // Dogfood r4: lastActive seeds the unread-dot contract
                    // (0 = unknown = never unread; this row is the
                    // deterministic dot target in the scripted fleet).
                    lastActive: 1_755_000_600, messageCount: 24, source: "ios"
                ),
            ]
        default:
            return [ScriptedFleet.session(gateway: route.gatewayID, slug: route.profileSlug.rawValue)]
        }
    }

    /// Gateway-qualified session identity. A session id belongs to the
    /// gateway that minted it: minting "workstation.<slug>.s1" for EVERY
    /// gateway made render-box's default-profile session collide with
    /// workstation's (two routes claiming one wire id — the Chats list
    /// then attributes the row to the wrong gateway).
    private static func session(gateway: GatewayID, slug: String) -> SessionSummary {
        SessionSummary(
            id: "\(gateway.rawValue).\(slug).s1", title: "Fleet setup",
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
        if FleetServiceGraph.connectSyncEnabled, gatewayID.rawValue == "workstation" {
            ScriptedConnectSyncStore.shared.markRecovered()
        }
        // Build 43: a workstation connect also closes the roster-blip
        // outage (HERMES_FLEET_ROSTER_BLIP user-driven journey).
        if gatewayID.rawValue == "workstation" {
            ScriptedConnectSyncStore.shared.markBlipReconnected()
        }
        // No-op: scripted connect succeeds instantly.
    }

    func disconnect() async {
        // Build 43: with the roster-blip knob set, a user Disconnect of the
        // workstation gateway fails its roster fetches until Connect heals
        // them (deterministic offline-ghost journey). Without the knob this
        // stays a no-op (scripted disconnect is safe from every state,
        // spec §31).
        if gatewayID.rawValue == "workstation" {
            ScriptedConnectSyncStore.shared.markBlipDisconnected()
        }
    }

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

/// State for the deterministic connect→roster recovery UI scenario.
final class ScriptedConnectSyncStore: @unchecked Sendable {
    static let shared = ScriptedConnectSyncStore()
    private let lock = NSLock()
    private var _recovered = false
    /// Build 43 UI-test knob (HERMES_FLEET_ROSTER_BLIP=1): while set, a user
    /// DISCONNECT of the workstation gateway (Gateways row menu) also fails
    /// its roster fetches, and Connect heals them. The fleet is healthy at
    /// launch — the offline-ghost cache seeds from the launch refresh — so
    /// the post-disconnect outage renders LAST-KNOWN ghost rows exactly
    /// like a real gateway drop (a fetch-count window is NOT used: the two
    /// concurrent launch refreshes race and can drop the first settlement,
    /// leaving the cache empty).
    private var _blipEnabled = ProcessInfo.processInfo.environment["HERMES_FLEET_ROSTER_BLIP"] == "1"
    private var _blipDisconnected = false

    var recovered: Bool {
        lock.lock(); defer { lock.unlock() }
        return _recovered
    }

    func markRecovered() {
        lock.lock(); defer { lock.unlock() }
        _recovered = true
    }

    /// True while the user-driven roster-blip outage is open.
    var rosterBlipOutage: Bool {
        lock.lock(); defer { lock.unlock() }
        return _blipEnabled && _blipDisconnected
    }

    /// A user Disconnect of the workstation gateway opened the outage.
    func markBlipDisconnected() {
        lock.lock(); defer { lock.unlock() }
        if _blipEnabled { _blipDisconnected = true }
    }

    /// A user Connect closed the outage (gateway healthy again).
    func markBlipReconnected() {
        lock.lock(); defer { lock.unlock() }
        _blipDisconnected = false
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

    /// FOS-4 UI-test knob: `HERMES_FLEET_AUTH_GATEWAY=1` makes the `arch`
    /// gateway a classified AUTH-REQUIRED failure (close 4401 shape) so the
    /// Home Needs You section (auth episode) is deterministically walkable.
    private var isAuthOutage: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_AUTH_GATEWAY"] == "1"
    }

    private var isOutage: Bool {
        if FleetServiceGraph.connectSyncEnabled,
           gatewayID.rawValue == "workstation",
           !ScriptedConnectSyncStore.shared.recovered {
            return true
        }
        guard !FleetServiceGraph.zeroBotsEnabled else { return false }
        return gatewayID.rawValue == "arch"
    }

    private var hasNoBots: Bool { FleetServiceGraph.zeroBotsEnabled }

    private var authFailure: Bool { isAuthOutage && gatewayID.rawValue == "arch" }

    var status: GatewayStatus {
        if authFailure { return .authenticationRequired }
        return isOutage ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if authFailure {
            throw GatewayConnectivityError.authenticationRequired
        }
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
        // Build 43 roster blip: a user-disconnected workstation fails its
        // roster fetches (offline-ghost journey; Connect heals).
        if gatewayID.rawValue == "workstation",
           ScriptedConnectSyncStore.shared.rosterBlipOutage {
            throw RosterError.notConnected
        }
        if hasNoBots { return [] }
        return ScriptedFleet.profiles(on: gatewayID)
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        if isOutage { throw RosterError.notConnected }
        if gatewayID.rawValue == "workstation",
           ScriptedConnectSyncStore.shared.rosterBlipOutage {
            throw RosterError.notConnected
        }
        return ScriptedFleet.sessions(on: route)
    }
}

/// Shared record of profiles created through scripted management seams in
/// this app process, so the scripted roster can surface created bots on the
/// next refresh (deterministic create-visible flow) — and of appearance
/// writes (metadata + avatar asset state) so a roster refresh after an
/// avatar Save reflects gateway-authoritative state (#7 UI journeys).
final class ScriptedBotProfileSeamStore: @unchecked Sendable {
    static let shared = ScriptedBotProfileSeamStore()
    private let lock = NSLock()
    private var created: [GatewayID: [ProfileDescriptor]] = [:]
    /// Appearance writes through scripted seams, keyed gateway → profile:
    /// hermes-bots metadata + whether an avatar asset exists.
    private var appearance: [GatewayID: [String: (metadata: BotModeMetadata, hasAvatar: Bool)]] = [:]

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

    func recordAppearance(
        gatewayID: GatewayID, profile: String,
        metadata: BotModeMetadata, hasAvatar: Bool) {
        lock.lock(); defer { lock.unlock() }
        appearance[gatewayID, default: [:]][profile] = (metadata, hasAvatar)
    }

    /// The authoritative scripted appearance for a profile, if a scripted
    /// seam ever wrote one (nil = keep the static descriptor).
    func appearanceOverlay(on gatewayID: GatewayID, profile: String)
        -> (metadata: BotModeMetadata, hasAvatar: Bool)? {
        lock.lock(); defer { lock.unlock() }
        return appearance[gatewayID]?[profile]
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
final class ScriptedBotProfileSeam: BotProfileManaging, BotSectionRegistryLoading, BotSectionRegistryWriting, BotPetManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let gatewayID: GatewayID
    private var metadataByProfile: [String: BotModeMetadata] = [:]
    private var revisionByProfile: [String: Int] = [:]
    private var avatarBytesByProfile: [String: Data] = [:]
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
            recordAppearanceWrite(profile)
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

    func uploadAvatar(_ profile: String, dataURL: String) async throws {
        storeAvatarBytes(profile, dataURL: dataURL)
        recordAppearanceWrite(profile)
    }

    func clearAvatar(_ profile: String) async throws {
        dropAvatarBytes(profile)
        recordAppearanceWrite(profile)
    }

    func avatarData(_ profile: String) async throws -> Data? {
        currentAvatarBytes(profile)
    }

    // MARK: i7-gapfill R1 — avatar upload / portrait generation surface

    /// The scripted fleet is asset-capable (mirrors a real gateway that
    /// speaks profiles.set_asset), so the Photos / Files / Clear controls
    /// render on the deterministic DEBUG fleet and are UI-testable.
    /// Env knob `HERMES_FLEET_AVATAR_UNSUPPORTED=1` scripts the honest
    /// unsupported state (the editor hides the upload controls).
    func supportsAvatarUpload(_ profile: String) async -> Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_AVATAR_UNSUPPORTED"] != "1"
    }

    /// Portrait generation is available on the scripted fleet; the
    /// preview/confirm staging journey is deterministic.
    func supportsPortraitGeneration() async -> Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_AVATAR_UNSUPPORTED"] != "1"
    }

    /// Deterministic generated-portrait fixture: a valid decodable PNG
    /// (the editor normalizes + stages it through the SAME path a real
    /// gateway portrait takes — never a local avatar authority).
    func generatePortrait(prompt: String) async throws -> Data {
        guard await supportsPortraitGeneration() else { throw BotPortraitError.unavailable }
        return ScriptedPetPNG.magenta
    }

    // MARK: #9 — scripted pet surface (pet.gallery / pet.thumb)

    /// Scripted Petdex rows per gateway. The SAME slug deliberately maps
    /// to different thumbnails per gateway (route-provenance proof: the
    /// cache and every request key on GatewayID + ProfileSlug + PetSlug).
    private static let petThumbnails: [String: [String: Data]] = [
        "workstation": [
            "spark-fox": ScriptedPetPNG.magenta,
            "pixel-owl": ScriptedPetPNG.green,
            "null-cat": ScriptedPetPNG.magenta,
        ],
        "render-box": [
            // Same three slugs, DIFFERENT images on this gateway.
            "spark-fox": ScriptedPetPNG.green,
            "pixel-owl": ScriptedPetPNG.magenta,
            "null-cat": ScriptedPetPNG.green,
        ],
    ]

    private func scriptedPets(for gatewayID: GatewayID, localOnly: Bool) -> [HermesPet] {
        let thumbs = Self.petThumbnails[gatewayID.rawValue] ?? [:]
        let rows: [HermesPet] = [
            HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                      curated: false, generated: false, spritesheetURL: nil),
            HermesPet(slug: "pixel-owl", displayName: "Pixel Owl", installed: false,
                      curated: true, generated: false,
                      spritesheetURL: "https://petdex.dev/sheets/pixel-owl.png"),
            HermesPet(slug: "null-cat", displayName: "Null Cat", installed: true,
                      curated: false, generated: true, spritesheetURL: nil),
        ]
        // Two-stage: localOnly returns installed/generated pets only.
        return localOnly ? rows.filter { thumbs[$0.slug] != nil && $0.installed } : rows
    }

    func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
        // petsUnsupported gate for the unavailable-state UI journey.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_PETS_UNSUPPORTED"] == "1" {
            throw BotPetError.petsUnavailable("Hermes Pets are not available on this gateway.")
        }
        if ProcessInfo.processInfo.environment["HERMES_FLEET_PETS_FAIL"] == "1" {
            throw BotModeProfileError.rpcFailed("transient fixture failure")
        }
        return HermesPetGallery(
            pets: scriptedPets(for: gatewayID, localOnly: localOnly),
            displayEnabled: true,
            activeSlug: "spark-fox")
    }

    func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
        guard let bytes = Self.petThumbnails[gatewayID.rawValue]?[slug] else {
            throw BotPetError.thumbnailUnavailable(slug: slug)
        }
        return bytes
    }

    /// Scripted roster support: whether an avatar asset exists for this
    /// profile (the `profiles.list has_avatar` equivalent) and the bot
    /// metadata written through the seam (the ui_meta equivalent).
    var hasAvatarByProfile: [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Bool] = [:]
        for profile in metadataByProfile.keys { out[profile] = avatarBytesByProfile[profile] != nil }
        return out
    }

    var metadataSnapshot: [String: BotModeMetadata] {
        lock.lock(); defer { lock.unlock() }
        return metadataByProfile
    }

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

    /// Push the current metadata + asset state into the shared store so
    /// the scripted roster reflects appearance writes on refresh (#7).
    /// Sync (lock-scoped) per the file's async-safe locking discipline.
    private func recordAppearanceWrite(_ profile: String) {
        lock.lock()
        let metadata = metadataByProfile[profile] ?? BotModeMetadata()
        let hasAvatar = avatarBytesByProfile[profile] != nil
        lock.unlock()
        ScriptedBotProfileSeamStore.shared.recordAppearance(
            gatewayID: gatewayID, profile: profile,
            metadata: metadata, hasAvatar: hasAvatar)
    }

    /// Sync lock-scoped avatar asset helpers (NSLock is unavailable from
    /// async contexts).
    private func storeAvatarBytes(_ profile: String, dataURL: String) {
        lock.lock(); defer { lock.unlock() }
        guard let range = dataURL.range(of: "base64,"),
              let data = Data(base64Encoded: String(dataURL[range.upperBound...])) else { return }
        avatarBytesByProfile[profile] = data
    }

    private func dropAvatarBytes(_ profile: String) {
        lock.lock(); defer { lock.unlock() }
        avatarBytesByProfile[profile] = nil
    }

    private func currentAvatarBytes(_ profile: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return avatarBytesByProfile[profile]
    }

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
/// Slice 4: the hosted room is INTERACTIVE (backed by `ScriptedRoomEngine`)
/// so create/open/message/rename/disband/stop/retry/approve are walkable
/// deterministically in the simulator + UI tests. The legacy room stays
/// observational (addendum).
struct ScriptedRoomSource: FleetRoomSourceProviding {
    let gatewayID: GatewayID

    func rooms() async -> [FleetRoom] {
        guard gatewayID.rawValue == "workstation" else { return [] }
        var rooms: [FleetRoom] = [await ScriptedRoomEngine.shared.hostedRoom(gatewayID: gatewayID)]
        rooms += await ScriptedRoomEngine.shared.createdRoomRows(gatewayID: gatewayID)
        if await ScriptedRoomEngine.shared.legacyRoomVisible {
            rooms.append(legacyRoom(gatewayID: gatewayID))
        }
        return rooms
    }

    /// F1: the workstation fixture mirrors a real gateway's
    /// `groups.capabilities` probe (driver + groups.create advertised);
    /// other scripted gateways fail closed (.unknown).
    func createRoomCapability() async -> GroupsCreateCapability {
        guard gatewayID.rawValue == "workstation" else { return .unknown }
        return .supported
    }

    private func legacyRoom(gatewayID: GatewayID) -> FleetRoom {
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
        )
    }
}

/// Slice 4 scripted engine: an in-memory hosted room faithful to the
/// gateway's groups.* semantics (durable log by seq, idempotent send,
/// tombstoned disband, stop/retry/approve counters) — deterministic UI-test
/// fixture, DEBUG simulator only. Env knobs (UI tests):
/// - `HERMES_FLEET_ROOM_FAILURE=1` — the room's transcript carries a typed
///   `turn.failed` (provider_auth_or_access) + a pending retry action.
/// - `HERMES_FLEET_ROOM_APPROVAL=1` — a needs-you approval is pending.
actor ScriptedRoomEngine: RoomChatCommanding, RoomDriverStatusProviding {
    static let shared = ScriptedRoomEngine()

    private var _events: [HostedRoomEventValue] = []
    private var _seq = 0
    private var _roomName = "Launch Crew"
    private var _disbanded = false
    private var _legacyRoomVisible = true
    private var _createdRooms: [String] = []
    private var _sendCount = 0
    private var _renameCount = 0
    private var _stopCount = 0
    private var _retryCount = 0
    private var _approveChoices: [String] = []
    private var _pendingApproval: RoomPendingApproval?
    private var _pendingRetry: RoomPendingRetry?
    private var _lastCreatedMembers: [[String: String]] = []
    private var _createdRoomNames: [String: String] = [:]
    private var _createdRoomMembers: [String: [FleetRoomMember]] = [:]
    private var _createdRoomAuthorities: [String: String] = [:]

    private init() {
        let seed = Self.makeSeed()
        _events = seed.events
        _seq = seed.seq
        _pendingRetry = seed.pendingRetry
        _pendingApproval = seed.pendingApproval
    }

    /// Pure seed builder (callable from nonisolated init AND isolated reset).
    private static func makeSeed()
        -> (events: [HostedRoomEventValue], seq: Int,
            pendingApproval: RoomPendingApproval?, pendingRetry: RoomPendingRetry?) {
        var events: [HostedRoomEventValue] = []
        var seq = 0
        func append(
            kind: String, actorKind: String, actorID: String, actorProfile: String? = nil,
            text: String?, reason: String? = nil
        ) {
            seq += 1
            events.append(HostedRoomEventValue(
                roomID: "room-alpha", seq: seq, eventID: "se-\(seq)", kind: kind,
                actorKind: actorKind, actorID: actorID, actorProfile: actorProfile,
                payloadText: text, reasonCode: reason, createdAt: Date().timeIntervalSince1970))
        }
        append(kind: "room.created", actorKind: "system", actorID: "system", text: nil)
        append(kind: "message.member", actorKind: "member", actorID: "researcher",
               actorProfile: "researcher", text: "Draft is ready for review.")
        // D3 (iPad lane): deterministic pre-seeded history for the
        // scroll-overflow suites. Typed filler text reflows width-dependent
        // — on the iPad canvas it shrinks ~3x and the transcript can fit
        // the viewport entirely, making "reading history" unreachable.
        // Seeded log lines overflow ANY canvas width. Env-gated; unset for
        // every other suite keeps the two-event seed unchanged.
        let env = ProcessInfo.processInfo.environment
        if let depthLine = env["HERMES_FLEET_ROOM_HISTORY_DEPTH"],
           let depth = Int(depthLine), depth > 0 {
            for index in 1...depth {
                append(kind: "message.member", actorKind: "member", actorID: "researcher",
                       actorProfile: "researcher",
                       text: "Seeded history \(index) of \(depth): durable room log line for scroll-overflow coverage.")
            }
        }
        var pendingRetry: RoomPendingRetry?
        var pendingApproval: RoomPendingApproval?
        if env["HERMES_FLEET_ROOM_FAILURE"] == "1" {
            append(kind: "turn.failed", actorKind: "gateway", actorID: "gateway",
                   actorProfile: "researcher",
                   text: "Provider rejected the request (auth).",
                   reason: "provider_auth_or_access")
            pendingRetry = RoomPendingRetry(taskID: "task-fail-1")
        }
        if env["HERMES_FLEET_ROOM_APPROVAL"] == "1" {
            pendingApproval = RoomPendingApproval(
                memberID: "researcher", taskID: "task-appr-1", executionGeneration: 2,
                requestID: "req-1",
                approval: ["prompt": .string("Allow the researcher to run the web tool?")])
        }
        return (events, seq, pendingApproval, pendingRetry)
    }

    /// Full reset to the deterministic seed (per-test isolation).
    func reset() {
        _roomName = "Launch Crew"
        _disbanded = false
        _legacyRoomVisible = true
        _createdRooms = []
        _sendCount = 0
        _renameCount = 0
        _stopCount = 0
        _retryCount = 0
        _approveChoices = []
        _lastCreatedMembers = []
        _createdRoomMembers = [:]
        _createdRoomAuthorities = [:]
        let seed = Self.makeSeed()
        _events = seed.events
        _seq = seed.seq
        _pendingApproval = seed.pendingApproval
        _pendingRetry = seed.pendingRetry
    }

    var roomKey: String { "room-alpha" }
    var roomNameValue: String { _roomName }
    var isDisbanded: Bool { _disbanded }
    var legacyRoomVisible: Bool { _legacyRoomVisible }
    var sendCount: Int { _sendCount }
    var stopCount: Int { _stopCount }
    var retryCount: Int { _retryCount }
    var renameCount: Int { _renameCount }
    var approveChoices: [String] { _approveChoices }
    var createdRoomIDs: [String] { _createdRooms }
    var lastCreatedMembers: [[String: String]] { _lastCreatedMembers }

    /// Seed a legacy same-name room (distinctness fixture) on/off.
    func setLegacyRoomVisible(_ visible: Bool) {
        _legacyRoomVisible = visible
    }

    func hostedRoom(gatewayID: GatewayID) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: roomKey),
            name: _roomName,
            members: [
                FleetRoomMember(name: "Researcher", handle: "researcher"),
                FleetRoomMember(name: "Default", handle: "default"),
            ],
            hosted: HostedRoomState(
                authorityGatewayID: "install:\(gatewayID.rawValue)",
                authorityEpoch: 1,
                latestSeq: _seq,
                advertisedMethods: [
                    "groups.create", "groups.send", "groups.rename", "groups.log",
                    "groups.disband", "groups.stop", "groups.retry", "groups.approve",
                ],
                driverAvailable: !_disbanded))
    }

    @discardableResult
    private func append(
        roomID: String? = nil,
        kind: String, actorKind: String, actorID: String, actorProfile: String? = nil,
        text: String?, reason: String? = nil
    ) -> HostedRoomEventValue {
        _seq += 1
        let event = HostedRoomEventValue(
            roomID: roomID ?? self.roomKey, seq: _seq, eventID: "se-\(_seq)", kind: kind,
            actorKind: actorKind, actorID: actorID, actorProfile: actorProfile,
            payloadText: text, reasonCode: reason, createdAt: Date().timeIntervalSince1970)
        _events.append(event)
        return event
    }

    // MARK: RoomChatCommanding

    func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
        let window = _events.filter { $0.roomID == roomID && $0.seq > sinceSeq }
        return RoomLogPageSlice(
            events: Array(window.prefix(limit)),
            cursor: _seq,
            latestSeq: _seq,
            hasMore: window.count > limit,
            authorityGatewayID: _createdRoomAuthorities[roomID] ?? "install:workstation",
            authorityEpoch: 1)
    }

    func send(roomID: String, text: String, threadID: String?) async throws -> Int {
        _sendCount += 1
        append(roomID: roomID, kind: "message.user", actorKind: "user", actorID: "desktop", text: text)
        return _seq
    }

    func rename(roomID: String, name: String) async throws {
        _renameCount += 1
        _roomName = name
        append(roomID: roomID, kind: "room.renamed", actorKind: "system", actorID: "system", text: name)
    }

    func disband(roomID: String) async throws {
        _disbanded = true
        append(roomID: roomID, kind: "room.disbanded", actorKind: "system", actorID: "system", text: nil)
    }

    func stop(roomID: String) async throws -> Int {
        _stopCount += 1
        append(roomID: roomID, kind: "room.stop_requested", actorKind: "gateway", actorID: "gateway", text: nil)
        return 1
    }

    func retry(roomID: String, taskID: String) async throws {
        _retryCount += 1
        _pendingRetry = nil
    }

    func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws {
        _approveChoices.append(choice)
        _pendingApproval = nil
    }

    func createRoom(roomID: String, name: String, members: [[String: String]]) async throws -> String {
        let roomKey = roomID.isEmpty ? "room-\(_createdRooms.count + 1)" : roomID
        recordCreatedRoom(
            roomID: roomKey,
            name: name,
            members: members.map {
                FleetRoomMember(
                    name: $0["display_name"] ?? $0["name"] ?? $0["profile"] ?? "Bot",
                    handle: $0["profile"])
            })
        _lastCreatedMembers = members
        append(roomID: roomKey, kind: "room.created", actorKind: "system", actorID: "system", text: nil)
        return roomKey
    }

    func recordCreatedRoom(roomID: String, name: String, members: [FleetRoomMember]) {
        if !_createdRooms.contains(roomID) {
            _createdRooms.append(roomID)
        }
        _createdRoomNames[roomID] = name
        _createdRoomMembers[roomID] = members
        _createdRoomAuthorities[roomID] = _createdRoomAuthorities[roomID] ?? "install:workstation"
    }

    func recordLinkedRoom(
        roomID: String, name: String, members: [FleetRoomMember], authorityGatewayID: String
    ) {
        recordCreatedRoom(roomID: roomID, name: name, members: members)
        _createdRoomAuthorities[roomID] = authorityGatewayID
        append(roomID: roomID, kind: "room.created", actorKind: "system", actorID: "system", text: nil)
    }

    /// FleetRoom rows for created rooms (fresh log per room; frozen roster
    /// from the wire members).
    func createdRoomRows(gatewayID: GatewayID) -> [FleetRoom] {
        _createdRooms.map { roomID in
            FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: roomID),
                name: _createdRoomNames[roomID] ?? roomID,
                members: _createdRoomMembers[roomID] ?? [],
                hosted: HostedRoomState(
                    authorityGatewayID: _createdRoomAuthorities[roomID] ?? "install:\(gatewayID.rawValue)",
                    authorityEpoch: 1,
                    advertisedMethods: [
                        "groups.create", "groups.send", "groups.rename", "groups.log",
                        "groups.disband", "groups.stop", "groups.retry", "groups.approve",
                    ],
                    driverAvailable: true))
        }
    }

    // MARK: RoomDriverStatusProviding

    func driverStatus(roomID: String) async throws -> RoomDriverStatus? {
        RoomDriverStatus(
            working: false,
            blocked: _pendingApproval != nil || _pendingRetry != nil,
            counts: [:],
            pendingRetries: _pendingRetry.map { [$0] } ?? [],
            pendingApprovals: _pendingApproval.map { [$0] } ?? [])
    }
}

/// Slice 5 (D19): scripted RoomLink engine (DEBUG simulator only) — a
/// deterministic `RoomLinkCommanding` faithful to the gateway's peer.*
/// semantics. Env knobs (UI tests):
/// - `HERMES_FLEET_ROOMLINK=unsupported` — the gateway reports RoomLink
///   disabled with reason `durable_run_storage_required` (honest unsupported
///   state; no grant is ever minted).
/// - `HERMES_FLEET_ROOMLINK=stale` — the replica starts BEHIND (lastSeq 4 of
///   latestSeq 10) so promotion is blocked until Replay now runs.
/// - default — supported direct/TLS catalog, caught-up replica.
actor ScriptedRoomLinkEngine: RoomLinkCommanding {
    static let shared = ScriptedRoomLinkEngine()

    private var mode: Mode {
        switch ProcessInfo.processInfo.environment["HERMES_FLEET_ROOMLINK"] {
        case "unsupported": return .unsupported
        case "stale": return .staleReplica
        default: return .supported
        }
    }

    private enum Mode {
        case supported
        case unsupported
        case staleReplica
    }

    private var _inviteCount = 0
    private var _revokeCount = 0
    private var _registerCount = 0
    private var _promoteConfirms: [Bool] = []
    private var _replicateCount = 0
    private var _replicaCaughtUp: Bool
    private let gatewayID: GatewayID

    init(gatewayID: GatewayID = GatewayID(rawValue: "workstation")) {
        self.gatewayID = gatewayID
        _replicaCaughtUp = ProcessInfo.processInfo.environment["HERMES_FLEET_ROOMLINK"] != "stale"
    }

    var inviteCount: Int { _inviteCount }
    var revokeCount: Int { _revokeCount }
    var registerCount: Int { _registerCount }
    var promoteConfirms: [Bool] { _promoteConfirms }
    var replicateCount: Int { _replicateCount }

    func reset() {
        _inviteCount = 0
        _revokeCount = 0
        _registerCount = 0
        _promoteConfirms = []
        _replicateCount = 0
        _replicaCaughtUp = mode != .staleReplica
    }

    private func supportedNegotiation(profile: String = "default") -> RoomLinkNegotiation {
        let identity = "install:\(gatewayID.rawValue)"
        return RoomLinkNegotiation(
            authorityGatewayID: identity,
            enabled: true,
            profile: profile,
            protocolVersions: [2],
            installationID: identity,
            linkModes: ["direct"],
            persistentProcess: true,
            textOnly: true,
            attachmentsSupported: false,
            catalogDigest: String(repeating: String(gatewayID.rawValue.first ?? "c"), count: 64),
            executionPolicy: RoomLinkExecutionPolicy(
                version: 1, targetProfile: profile,
                enabledToolsets: ["bot_room"], approvalMode: "manual",
                maxIterations: 12, policyDigest: String(repeating: String(profile.first ?? "p"), count: 64)),
            endpoint: RoomLinkEndpoint(
                available: true,
                url: "https://\(gatewayID.rawValue).roomlink.fixture.test/v1",
                transportSecurity: "tls"),
            methods: [
                "groups.capabilities", "groups.create", "groups.state", "groups.send",
                "groups.rename", "groups.log", "groups.disband", "groups.stop",
                "groups.retry", "groups.approve",
                "groups.peer.invite", "groups.peer.register",
                "groups.peer.revoke", "groups.replica_state", "groups.replicate",
                "groups.promote", "groups.demote",
            ])
    }

    // MARK: RoomLinkCommanding

    func negotiate() async throws -> RoomLinkNegotiation {
        switch mode {
        case .supported, .staleReplica:
            return supportedNegotiation()
        case .unsupported:
            return RoomLinkNegotiation(
                authorityGatewayID: "install:\(gatewayID.rawValue)",
                enabled: false,
                disabledReason: .durableRunStorageRequired)
        }
    }

    func invite(
        roomID: String?, memberID: String?, ttlSeconds: Double
    ) async throws -> RoomLinkGrant {
        guard mode != .unsupported else {
            throw RoomCommandFailure.unsupportedMethod("groups.peer.invite")
        }
        _inviteCount += 1
        let now = Date()
        return RoomLinkGrant(
            id: "grant-\(_inviteCount)",
            token: "fixture-grant-\(_inviteCount)-0123456789abcdef",
            roomID: roomID,
            memberID: memberID ?? "researcher",
            targetProfile: "researcher",
            permissions: RoomLinkGrant.Permission.allCases,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds))
    }

    func registerPeer(
        roomID: String, memberID: String, grant: RoomLinkGrant,
        targetURL: String
    ) async throws -> RoomPeerRoute {
        _registerCount += 1
        return RoomPeerRoute(
            roomID: roomID, memberID: memberID,
            targetInstallID: "install:remote", targetProfile: grant.targetProfile,
            mode: "direct", transportSecurity: "tls", status: .ready)
    }

    func revoke(grant: RoomLinkGrant) async throws {
        _revokeCount += 1
    }

    func peerRoutes(roomID: String) async throws -> [RoomPeerRoute] {
        guard mode != .unsupported else { return [] }
        return [RoomPeerRoute(
            roomID: roomID, memberID: "researcher",
            targetInstallID: "install:remote", targetProfile: "researcher",
            mode: "direct", transportSecurity: "tls", status: .ready)]
    }

    func replicaState(roomID: String) async throws -> RoomReplicaState? {
        guard mode != .unsupported else { return nil }
        // Replica of a FOREIGN authority ("install:hub") — the only state
        // upstream promote_replica allows promoting. Authority == local
        // would be an honest "already holds the room authority" refusal.
        return RoomReplicaState(
            roomID: roomID, name: "Launch Crew",
            authorityGatewayID: "install:hub", authorityEpoch: 3,
            lastSeq: _replicaCaughtUp ? 10 : 4,
            latestSeq: 10,
            eventBytes: 4096, createdAt: 1, updatedAt: 2)
    }

    func roomReplaySource(roomID: String) async throws -> any RoomReplaySourceProviding {
        ScriptedRoomReplaySource()
    }

    func replicateSink() async throws -> any RoomReplicateSink {
        self
    }

    func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt {
        _promoteConfirms.append(confirm)
        guard confirm else {
            throw RoomCommandFailure.confirmRequired(
                "promotion requires confirm=true acknowledging the previous authority can no longer commit")
        }
        guard _replicaCaughtUp else {
            throw RoomCommandFailure.rpcFailed("replica is behind the authority log", 0)
        }
        // Upstream promote_replica shape: THIS gateway ("install:workstation")
        // becomes the authority at epoch+1; the foreign authority it took
        // over ("install:hub") is named as previous — consistent with
        // replicaState above.
        return RoomPromotionReceipt(
            roomID: roomID,
            authorityGatewayID: "install:workstation", authorityEpoch: 4,
            previousGatewayID: "install:hub", previousEpoch: 3,
            claimSeq: 11, latestSeq: 10)
    }

    func demote(roomID: String, observedGatewayID: String, observedEpoch: Int) async throws {}
}

/// Scripted authority replay surface: real-shaped `groups.state` room row +
/// one caught-up `groups.log` page (mirrors upstream shapes deterministically
/// for the DEBUG simulator + UI tests).
private struct ScriptedRoomReplaySource: RoomReplaySourceProviding {
    func roomProfile(roomID: String) async throws -> RoomReplayProfile {
        RoomReplayProfile(
            roomID: roomID,
            name: "Launch Crew",
            members: .array([
                .object(["member_id": .string("researcher"), "profile": .string("researcher")]),
                .object(["member_id": .string("fleet"), "profile": .string("default")]),
            ]),
            authorityGatewayID: "install:hub",
            authorityEpoch: 3)
    }

    func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage {
        RoomReplayLogPage(
            roomID: roomID,
            page: .object([
                "events": .array([]),
                "cursor": .number(10),
                "latest_seq": .number(10),
                "has_more": .bool(false),
                "authority": .object([
                    "gateway_id": .string("install:hub"),
                    "epoch": .number(3)]),
            ]),
            cursor: 10,
            latestSeq: 10,
            hasMore: false,
            authorityGatewayID: "install:hub",
            authorityEpoch: 3)
    }
}

/// The simulator's cross-gateway setup uses the same capability and grant
/// gates as production, while keeping the room state in the in-memory hosted
/// room engine. This lets UI tests exercise a real multi-route create without
/// pretending that a local roster union is server replication.
extension ScriptedRoomLinkEngine: CrossGatewayRoomCommanding {
    func roomLinkTarget(profile: String) async throws -> RoomLinkTargetSnapshot {
        guard mode != .unsupported else {
            return RoomLinkTargetSnapshot(
                negotiation: RoomLinkNegotiation(
                    authorityGatewayID: "install:\(gatewayID.rawValue)",
                    enabled: false,
                    disabledReason: .durableRunStorageRequired,
                    profile: profile),
                catalog: .object([:]),
                driver: false)
        }
        let negotiation = supportedNegotiation(profile: profile)
        return RoomLinkTargetSnapshot(
            negotiation: negotiation,
            catalog: Self.catalog(for: negotiation),
            driver: true)
    }

    func createScopedRoom(
        roomID: String, name: String, members: [MetadataValue]
    ) async throws -> FleetRoom {
        guard mode != .unsupported else {
            throw RoomCommandFailure.unsupportedMethod("groups.create")
        }
        let normalized = members.compactMap(Self.decodeMember)
        let room = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: roomID),
            name: name,
            members: normalized,
            hosted: HostedRoomState(
                authorityGatewayID: "install:\(gatewayID.rawValue)",
                authorityEpoch: 1,
                latestSeq: 0,
                advertisedMethods: supportedNegotiation().methods,
                driverAvailable: true))
        await ScriptedRoomEngine.shared.recordLinkedRoom(
            roomID: roomID, name: name, members: normalized,
            authorityGatewayID: "install:\(gatewayID.rawValue)")
        return room
    }

    func inviteScopedRoom(
        room: FleetRoom, profile: String, memberID: String
    ) async throws -> ScopedRoomGrant {
        guard mode != .unsupported else {
            throw RoomCommandFailure.unsupportedMethod("groups.peer.invite")
        }
        _inviteCount += 1
        let negotiation = supportedNegotiation(profile: profile)
        return ScopedRoomGrant(
            token: "fixture-grant-\(_inviteCount)-0123456789abcdef",
            profile: profile,
            catalog: Self.catalog(for: negotiation))
    }

    func registerScopedPeer(
        roomID: String, memberID: String, target: RoomLinkTargetSnapshot,
        grant: ScopedRoomGrant
    ) async throws {
        guard target.supportsTarget,
              grant.profile == target.negotiation.profile,
              grant.catalog == target.catalog else {
            throw RoomCommandFailure.rpcFailed(
                "The target policy or capability catalog changed; refresh before linking.", 0)
        }
        _registerCount += 1
    }

    func revokeScopedPeer(_ grant: ScopedRoomGrant) async throws {
        _revokeCount += 1
    }

    private static func decodeMember(_ value: MetadataValue) -> FleetRoomMember? {
        guard let object = value.objectValue,
              let name = object["display_name"]?.stringValue
                ?? object["profile"]?.stringValue else { return nil }
        let target = object["target"]?.objectValue
        return FleetRoomMember(
            name: name,
            handle: object["profile"]?.stringValue,
            connectionID: target?["installation_id"]?.stringValue,
            sourceScoped: target?["kind"]?.stringValue == "peer")
    }

    private static func catalog(for negotiation: RoomLinkNegotiation) -> MetadataValue {
        var object: [String: MetadataValue] = [
            "protocol_versions": .array(negotiation.protocolVersions.map { .number(Double($0)) }),
            "installation_id": .string(negotiation.installationID),
            "link_modes": .array(negotiation.linkModes.map(MetadataValue.string)),
            "persistent_process": .bool(negotiation.persistentProcess),
            "text": .bool(negotiation.textOnly),
            "attachments": .bool(negotiation.attachmentsSupported),
            "catalog_digest": .string(negotiation.catalogDigest),
        ]
        if let policy = negotiation.executionPolicy {
            object["execution_policy"] = .object([
                "version": .number(Double(policy.version)),
                "target_profile": .string(policy.targetProfile),
                "enabled_toolsets": .array(policy.enabledToolsets.map(MetadataValue.string)),
                "approval_mode": .string(policy.approvalMode),
                "max_iterations": .number(Double(policy.maxIterations)),
                "policy_digest": .string(policy.policyDigest),
            ])
        }
        if let endpoint = negotiation.endpoint {
            object["endpoint"] = .object([
                "available": .bool(endpoint.available),
                "url": endpoint.url.map(MetadataValue.string) ?? .null,
                "transport_security": endpoint.transportSecurity.map(MetadataValue.string) ?? .null,
            ])
        }
        return .object(object)
    }
}

extension ScriptedRoomLinkEngine: RoomReplicateSink {
    func replicate(
        roomID: String, roomName: String, members: MetadataValue, page: MetadataValue
    ) async throws -> RoomReplicateReceipt {
        _replicateCount += 1
        _replicaCaughtUp = true
        return RoomReplicateReceipt(
            roomID: roomID, storedSeq: 10, ingested: 6,
            authorityGatewayID: "install:hub", authorityEpoch: 3,
            caughtUp: true)
    }
}

#endif
