import XCTest
import FleetCore
import FleetPersistence
import FleetUI
@testable import HermesFleetApp

/// R9-T2/T3/T4 — conversation tooling: sticky per-device model pick (rides
/// session.create ONLY — never config.set), context meter thresholds +
/// streamed usage ticks, steer/rename/fork over the scripted seam.
@MainActor
final class ConversationToolingTests: XCTestCase {

    // MARK: - Scripted seams

    private final class ScriptedTooling: ConversationToolingProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _steerTexts: [String] = []
        private var _renames: [String] = []
        private var _branches: [String?] = []
        var usageResult: Result<SessionUsageSnapshot, Error> =
            .success(SessionUsageSnapshot(
                model: "hermes", input: 100, output: 20, total: 120, calls: 2,
                contextUsed: 90_000, contextMax: 120_000, contextPercent: 75))
        var breakdownResult: Result<ContextBreakdown, Error> =
            .success(ContextBreakdown(
                categories: [
                    ContextBreakdownCategory(id: "system_prompt", label: "System prompt", tokens: 5_200),
                    ContextBreakdownCategory(id: "conversation", label: "Conversation", tokens: 38_000),
                ],
                contextMax: 120_000, contextPercent: 41, contextUsed: 49_200,
                estimatedTotal: 50_000, model: "hermes"))
        var steerQueued = true
        var modelChoicesError: Error?

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

        func modelChoices(sessionID: String?) async throws -> [ModelChoice] {
            if let modelChoicesError { throw modelChoicesError }
            return [
                ModelChoice(model: "hermes", provider: "nous", providerName: "Nous Research", isCurrent: true),
                ModelChoice(model: "gpt-5", provider: "openrouter", providerName: "OpenRouter", isCurrent: false),
            ]
        }

        func usage(sessionID: String) async throws -> SessionUsageSnapshot {
            try usageResult.get()
        }

        func contextBreakdown(sessionID: String) async throws -> ContextBreakdown {
            try breakdownResult.get()
        }

        func steer(sessionID: String, text: String) async throws -> Bool {
            record { $0._steerTexts.append(text) }
            return steerQueued
        }

        func renameSession(sessionID: String, title: String) async throws -> String {
            record { $0._renames.append(title) }
            return title
        }

        func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
            record { $0._branches.append(name) }
            return ConversationSession(
                sessionID: "branch-1", storedSessionID: "s-b1",
                messageCount: 2,
                messages: [
                    SessionMessage(role: .user, text: "hi"),
                    SessionMessage(role: .assistant, text: "hello"),
                ],
                model: "hermes", provider: "nous", profileName: nil)
        }

        /// Async-safe scoped recorder (NSLock is unavailable from async
        /// contexts on this toolchain).
        private func record(_ body: (ScriptedTooling) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(self)
        }
    }

    /// Records every conversation RPC (thread-safe) so the sticky-local
    /// rule is provable: a picker selection produces NO wire call at all.
    private final class RecordingConversation: ConversationProviding, @unchecked Sendable {
        struct CreateCall: Equatable {
            let model: String?
            let provider: String?
        }
        private let lock = NSLock()
        private var _createCalls: [CreateCall] = []
        private var _methods: [String] = []
        private let continuations = ScriptedEventFanout()

        var createCalls: [CreateCall] {
            lock.lock(); defer { lock.unlock() }
            return _createCalls
        }
        /// Every method invoked besides createSession.
        var otherMethods: [String] {
            lock.lock(); defer { lock.unlock() }
            return _methods
        }

        private func recordCreate(_ call: CreateCall) {
            lock.lock(); _createCalls.append(call); lock.unlock()
        }
        private func recordMethod(_ name: String) {
            lock.lock(); _methods.append(name); lock.unlock()
        }

        var events: AsyncStream<ConversationEvent> { continuations.stream }

        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            recordCreate(CreateCall(model: model, provider: provider))
            return ConversationSession(
                sessionID: "s-1", model: model ?? "default-model",
                provider: provider ?? "nous", profileName: profile)
        }

        func resumeSession(sessionID: String, lastEventID: Int?) async throws -> ConversationSession {
            recordMethod("session.resume")
            return ConversationSession(sessionID: sessionID)
        }

        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            recordMethod("prompt.submit")
            return PromptSubmission(status: "streaming")
        }

        func interrupt(sessionID: String) async throws -> InterruptResult {
            recordMethod("session.interrupt")
            return InterruptResult(status: "interrupted")
        }

        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
    }

    /// Minimal fan-out (fresh stream per subscriber, like the sim fixture).
    private final class ScriptedEventFanout: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<ConversationEvent>.Continuation] = [:]

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
            lock.lock(); defer { lock.unlock() }
            continuations.removeValue(forKey: id)
        }
    }

    /// Scripted conversation session capturing createSession's model params.
    private struct ScriptedToolingSession: ConversationSessionProviding, ConversationToolingCapable {
        let gatewayID = GatewayID(rawValue: "workstation")
        let recording: RecordingConversation
        let toolingProvider: any ConversationToolingProviding

        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "workstation", endpoint: nil)
        }
        func reauthenticate() async throws {}

        var conversation: any ConversationProviding { recording }
        var tooling: any ConversationToolingProviding { toolingProvider }
        var replay: any ReplayProviding { NoopReplay() }
        var history: any SessionHistoryProviding { EmptyHistory() }

        private struct NoopReplay: ReplayProviding {
            let gatewayID = GatewayID(rawValue: "workstation")
            func watermarks() async -> [SessionEventWatermark] { [] }
            func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        }

        private struct EmptyHistory: SessionHistoryProviding {
            func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
                SessionHistory(sessionID: sessionID, count: 0, messages: [])
            }
            func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
                SessionStatus.parse(output: "")
            }
        }
    }

    private func makeVM(tooling: ScriptedTooling) async -> (RecordingConversation, ConversationViewModel) {
        let recording = RecordingConversation()
        let session = ScriptedToolingSession(recording: recording, toolingProvider: tooling)
        let cache = try! SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        let vm = ConversationViewModel(
            session: session, cache: cache, route: route, sessionID: nil,
            statusInterval: .milliseconds(10))
        await vm.start()
        return (recording, vm)
    }

    // MARK: - R9-T2: sticky model pick

    func testStickyPickRidesSessionCreateOnly() async {
        // Clear any persisted pick from a previous test run.
        let key = "fleet.modelpick.workstation"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let tooling = ScriptedTooling()
        let (recording, vm) = await makeVM(tooling: tooling)

        // No pick: create rides nil/nil (inherit the profile default).
        XCTAssertEqual(recording.createCalls, [.init(model: nil, provider: nil)])

        // Simulate the picker selecting a model (as ModelPickerSheet would).
        let pick = ModelChoice(model: "gpt-5", provider: "openrouter", providerName: "OpenRouter", isCurrent: false)
        vm.toolingViewModel?.select(pick)
        XCTAssertEqual(vm.toolingViewModel?.selectedModel?.model, "gpt-5")

        // THE STICKY-LOCAL RULE: the pick produced NO wire call of any kind
        // (no config.set, no prompt.submit, nothing) — it only affects the
        // NEXT session.create.
        XCTAssertTrue(recording.otherMethods.isEmpty,
                      "a picker selection must never hit the wire directly")
        XCTAssertEqual(recording.createCalls.count, 1)

        // Persistence: a fresh tooling VM restores the same pick.
        let restored = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        XCTAssertEqual(restored.selectedModel?.model, "gpt-5")
        XCTAssertEqual(restored.createModelParams.model, "gpt-5")
        XCTAssertEqual(restored.createModelParams.provider, "openrouter")
    }

    func testStickyPickPersistsAcrossVMRestartAndResetClears() async {
        let key = "fleet.modelpick.workstation"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let tooling = ScriptedTooling()
        let pick = ModelChoice(model: "hermes", provider: "nous", providerName: "Nous Research", isCurrent: true)
        let first = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        first.select(pick)

        let second = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        XCTAssertEqual(second.selectedModel?.id, pick.id, "sticky pick survives a VM rebuild")

        // Reset clears it (follow-profile-default).
        second.select(nil)
        XCTAssertNil(second.selectedModel)
        let third = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        XCTAssertNil(third.selectedModel, "reset clears the persisted pick")
    }

    func testModelChoicesLoadFailSoft() async {
        let tooling = ScriptedTooling()
        tooling.modelChoicesError = ConversationError.notConnected
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        await vm.loadModelChoices()
        XCTAssertNil(vm.modelChoices)
        XCTAssertNotNil(vm.modelLoadError)
    }

    func testModelChoicesLoadAndMarkCurrent() async {
        let tooling = ScriptedTooling()
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        await vm.loadModelChoices()
        XCTAssertEqual(vm.modelChoices?.count, 2)
        XCTAssertEqual(vm.modelChoices?.first?.model, "hermes")
        XCTAssertEqual(vm.modelChoices?.first?.isCurrent, true)
        XCTAssertNil(vm.modelLoadError)
    }

    // MARK: - R9-T3: context meter

    func testMeterLevelThresholds() {
        // Plan Task 5: normal <70%, warn 70–90%, alert >90%.
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 0), .normal)
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 69), .normal)
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 70), .warn)
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 90), .warn)
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 91), .alert)
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 100), .alert)
        // Out-of-range clamps.
        XCTAssertEqual(ContextMeterLevel.level(forPercent: -5), .normal)
        XCTAssertEqual(ContextMeterLevel.level(forPercent: 150), .alert)
    }

    func testUsageTickFeedsMeterAndRPCSettles() async {
        let tooling = ScriptedTooling()
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        vm.bind(sessionID: "s-1")

        // No snapshot → unknown.
        XCTAssertNil(vm.usage)
        XCTAssertNil(vm.meterLevel)

        // Streamed tick (mid-turn, 75% → warn).
        vm.applyUsage(SessionUsageSnapshot(
            model: "hermes", input: 1, output: 1, total: 2, calls: 1,
            contextUsed: 90_000, contextMax: 120_000, contextPercent: 75))
        XCTAssertEqual(vm.usage?.contextPercent, 75)
        XCTAssertEqual(vm.meterLevel, .warn)

        // RPC refresh settles the figure.
        await vm.refreshUsage()
        XCTAssertEqual(vm.usage?.contextPercent, 75)
        XCTAssertTrue(vm.usage?.hasContextGauge ?? false)
    }

    func testNoGaugeSnapshotIsHonestUnknown() {
        let vm = ConversationToolingViewModel(
            tooling: ScriptedTooling(), gatewayID: GatewayID(rawValue: "workstation"))
        // server.py:7542: no context fields → unknown, never 0%.
        vm.applyUsage(SessionUsageSnapshot(model: "hermes", input: 10, output: 5, total: 15, calls: 1))
        XCTAssertFalse(vm.usage?.hasContextGauge ?? true)
        XCTAssertNil(vm.meterLevel, "no gauge → no level (unknown)")
    }

    func testBreakdownDecodesPerCategoryTokens() async {
        let tooling = ScriptedTooling()
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        vm.bind(sessionID: "s-1")
        await vm.loadBreakdown()
        XCTAssertEqual(vm.breakdown?.categories.count, 2)
        XCTAssertEqual(vm.breakdown?.categories.first?.label, "System prompt")
        XCTAssertEqual(vm.breakdown?.contextPercent, 41)
        XCTAssertNil(vm.contextError)

        // Compact token formatting (meter figures).
        XCTAssertEqual(ContextBreakdownSheet.compact(999), "999")
        XCTAssertEqual(ContextBreakdownSheet.compact(45_000), "45.0k")
        XCTAssertEqual(ContextBreakdownSheet.compact(1_250_000), "1.2M")
    }

    // MARK: - R9-T4: steer / rename / fork

    func testSteerQueuedSurfacesNotice() async {
        let tooling = ScriptedTooling()
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        vm.bind(sessionID: "s-1")

        await vm.steer(text: "keep it short")
        XCTAssertEqual(tooling.steerTexts, ["keep it short"])
        XCTAssertEqual(vm.steerNotice, "Steer queued — the model sees it on its next step.")

        tooling.steerQueued = false
        await vm.steer(text: "nudge")
        XCTAssertEqual(vm.steerNotice, "Steer rejected — no turn is running to steer.")
    }

    func testRenameAdoptsResolvedTitle() async {
        let tooling = ScriptedTooling()
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        vm.bind(sessionID: "s-1")

        let resolved = await vm.rename(title: "Fleet review")
        XCTAssertEqual(resolved, "Fleet review")
        XCTAssertEqual(tooling.renames, ["Fleet review"])

        // Empty rename never hits the wire.
        await vm.rename(title: "   ")
        XCTAssertEqual(tooling.renames.count, 1)
    }

    func testForkReturnsNewSessionAndFailureSurfacesError() async {
        let tooling = ScriptedTooling()
        let vm = ConversationToolingViewModel(
            tooling: tooling, gatewayID: GatewayID(rawValue: "workstation"))
        vm.bind(sessionID: "s-1")

        let branch = await vm.fork(name: nil)
        XCTAssertEqual(branch?.sessionID, "branch-1")
        XCTAssertEqual(branch?.messages.count, 2)
        XCTAssertNil(vm.forkError)

        // Failure path: nothing to branch (4008) surfaces forkError.
        struct NothingToBranch: ConversationToolingProviding {
            func modelChoices(sessionID: String?) async throws -> [ModelChoice] { [] }
            func usage(sessionID: String) async throws -> SessionUsageSnapshot { SessionUsageSnapshot() }
            func contextBreakdown(sessionID: String) async throws -> ContextBreakdown { ContextBreakdown(categories: []) }
            func steer(sessionID: String, text: String) async throws -> Bool { true }
            func renameSession(sessionID: String, title: String) async throws -> String { title }
            func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
                throw ConversationError.invalidRequest("nothing to branch — send a message first")
            }
        }
        let failing = ConversationToolingViewModel(
            tooling: NothingToBranch(), gatewayID: GatewayID(rawValue: "workstation"))
        failing.bind(sessionID: "s-1")
        let none = await failing.fork(name: nil)
        XCTAssertNil(none)
        XCTAssertNotNil(failing.forkError)
    }

    func testConversationVMForkNavigationRoundTrip() async {
        let tooling = ScriptedTooling()
        let (_, vm) = await makeVM(tooling: tooling)
        await vm.forkSession()
        XCTAssertEqual(vm.forkedSession?.sessionID, "branch-1")
        vm.consumeForkedSession()
        XCTAssertNil(vm.forkedSession, "consumed fork clears the navigation target")
    }
}
