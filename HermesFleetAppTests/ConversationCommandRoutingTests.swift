import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// Slash-command parity — ConversationViewModel routing coverage: native
/// actions (steer/new/stop/title/branch), pickers, dedicated RPC, backend
/// exec, dispatch interpretation, and the fail-closed unknown/stale paths.
/// Uses a self-contained scripted session (same one-class pattern as
/// ConversationViewModelTests' ScriptedSession).
@MainActor
final class ConversationCommandRoutingTests: XCTestCase {

    // MARK: - Scripted doubles

    private final class RoutingSession:
        ConversationSessionProviding,
        ConversationProviding,
        ReplayProviding,
        SessionHistoryProviding,
        ConversationToolingCapable,
        SlashCommandCapable,
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "workstation")

        // connectivity
        var status: GatewayStatus = .online
        var liveness: ConnectionLivenessSnapshot?
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "Workstation")
        }
        func reauthenticate() async throws {}

        // conversation
        var createdTitles: [String?] = []
        var submittedTexts: [String] = []
        var interruptCount = 0
        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }

        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            createdTitles.append(title)
            return ConversationSession(sessionID: "fresh-\(createdTitles.count)", profileName: profile)
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String? = nil) async throws -> ConversationSession {
            ConversationSession(sessionID: sessionID, profileName: "default")
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            submittedTexts.append(text)
            return PromptSubmission(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult {
            interruptCount += 1
            return InterruptResult(status: "interrupted")
        }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        var events: AsyncStream<ConversationEvent> {
            AsyncStream { $0.finish() }
        }

        // replay
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }

        // history
        var statusFetches: [String] = []
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            statusFetches.append(sessionID)
            return SessionStatus.parse(output: "Session ID: \(sessionID)\nModel: test-model (sim)")
        }

        // tooling
        var toolingBox = RecordingToolingBox()
        var tooling: any ConversationToolingProviding { toolingBox }

        // slash
        var slashBox = RoutingCommandBox()
        var slashCommands: any SlashCommandProviding { slashBox }
    }

    private final class RoutingCommandBox: SlashCommandProviding, @unchecked Sendable {
        var executedCommands: [String] = []
        var dispatchedNames: [String] = []
        var executeResult: HermesSlashExecution =
            HermesSlashExecution(output: "backend output", warning: nil)
        var executeError: SlashCommandError?
        /// When set, the FIRST execute() returns this once (alias chains).
        var oneShotResult: HermesSlashExecution?

        func catalog(sessionID: String?) async throws -> HermesCommandCatalog {
            HermesCommandCatalog(
                commands: [
                    SlashCommandSuggestion(text: "/steer", kind: .command, argumentMode: .text),
                    SlashCommandSuggestion(text: "/new", kind: .command),
                    SlashCommandSuggestion(text: "/status", kind: .command),
                    SlashCommandSuggestion(text: "/usage", kind: .command),
                    SlashCommandSuggestion(text: "/undo", kind: .command),
                    SlashCommandSuggestion(text: "/deploy-check", kind: .extensionCommand),
                    SlashCommandSuggestion(text: "/redraw", kind: .command, desktopDisposition: "terminal"),
                ],
                canon: ["/reset": "/new", "/fork": "/branch", "/switch": "/resume", "/sessions": "/resume"],
                commandMeta: [
                    "/redraw": SlashCommandSuggestion(text: "/redraw", kind: .command, desktopDisposition: "terminal"),
                ],
                skills: [:])
        }

        func complete(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] { [] }

        func dispatch(sessionID: String, name: String, argument: String) async throws -> HermesCommandDispatch {
            dispatchedNames.append(name)
            return .skill(message: "expanded", display: "/\(name)")
        }

        func execute(sessionID: String, command: String) async throws -> HermesSlashExecution {
            executedCommands.append(command)
            if let executeError { throw executeError }
            if let oneShot = oneShotResult {
                oneShotResult = nil
                return oneShot
            }
            return executeResult
        }

        func stopProcesses(sessionID: String) async throws -> Int { 2 }
    }

    private final class RecordingToolingBox: ConversationToolingProviding, @unchecked Sendable {
        var steerTexts: [String] = []
        var renames: [String] = []
        var branchNames: [String?] = []
        func modelChoices(sessionID: String?) async throws -> [ModelChoice] { [] }
        func usage(sessionID: String) async throws -> SessionUsageSnapshot { SessionUsageSnapshot() }
        func contextBreakdown(sessionID: String) async throws -> ContextBreakdown {
            ContextBreakdown(categories: [])
        }
        func steer(sessionID: String, text: String) async throws -> Bool {
            steerTexts.append(text)
            return true
        }
        func renameSession(sessionID: String, title: String) async throws -> String {
            renames.append(title)
            return title
        }
        func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
            branchNames.append(name)
            return ConversationSession(sessionID: "branched-1", profileName: "default")
        }
    }

    // MARK: - Fixture

    private var cache: SwiftDataCacheStore!

    private func makeFixture(sessionID: String? = "s1") async throws -> (RoutingSession, ConversationViewModel) {
        let session = RoutingSession()
        cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let viewModel = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: sessionID)
        await viewModel.start()
        return (session, viewModel)
    }

    // MARK: - Native actions

    func testSteerRoutesThroughToolingSeamNotBackend() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/steer focus on the auth flow")
        XCTAssertTrue(sent)
        XCTAssertTrue(session.toolingBox.steerTexts.contains("focus on the auth flow"),
                      "steer must ride the existing session.steer seam")
        XCTAssertTrue(session.slashBox.executedCommands.isEmpty,
                      "native commands never hit backend execution")
        XCTAssertTrue(session.submittedTexts.isEmpty)
    }

    func testEmptySteerArgumentReturnsUsageGuidance() async throws {
        let (_, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/steer")
        XCTAssertFalse(sent)
        XCTAssertEqual(
            viewModel.commandSuggestionError,
            "Usage: /steer <guidance> — injects guidance after the next tool call.")
    }

    func testNewCreatesFreshSessionAndNavigates() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/new")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.createdTitles, [nil],
                       "bare /new creates an untitled session")
        XCTAssertEqual(viewModel.commandNavigation, .newConversation(sessionID: "fresh-1"))
        XCTAssertTrue(session.submittedTexts.isEmpty,
                      "/new must never submit model text")
    }

    func testNewWithArgumentNamesTheSession() async throws {
        let (session, viewModel) = try await makeFixture()
        _ = await viewModel.send("/new auth experiment")
        XCTAssertEqual(session.createdTitles, ["auth experiment"])
    }

    func testResetAliasResolvesToNew() async throws {
        let (session, viewModel) = try await makeFixture()
        _ = await viewModel.send("/reset")
        XCTAssertEqual(session.createdTitles.count, 1,
                       "alias /reset resolves to the same native /new action")
    }

    func testTitleRoutesThroughRenameSeam() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/title Renamed Chat")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.toolingBox.renames, ["Renamed Chat"])
    }

    func testBranchRoutesThroughBranchSeamAndFiresNavigation() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/branch explore b")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.toolingBox.branchNames, ["explore b"])
        XCTAssertEqual(viewModel.forkedSession?.sessionID, "branched-1")
    }

    func testForkAliasBranches() async throws {
        let (session, viewModel) = try await makeFixture()
        _ = await viewModel.send("/fork")
        XCTAssertEqual(session.toolingBox.branchNames.count, 1)
    }

    func testStatusRoutesThroughHistorySeamAndRendersOutput() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/status")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.statusFetches, ["s1"])
        XCTAssertTrue(viewModel.transcript.contains { $0.text.contains("Session ID: s1") },
                      "status renders as a system row")
    }

    // MARK: - Pickers

    func testModelCommandOpensNativePicker() async throws {
        let (_, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/model")
        XCTAssertTrue(sent)
        XCTAssertEqual(viewModel.commandNavigation, .modelPicker)
    }

    func testSessionsCommandRoutesToNativeSessionsList() async throws {
        let (_, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/sessions")
        XCTAssertTrue(sent)
        XCTAssertEqual(viewModel.commandNavigation, .sessionsList)
    }

    // MARK: - Backend execution

    func testBackendExecCommandRendersOutputWithoutPromptingModel() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/usage")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.slashBox.executedCommands, ["/usage"])
        XCTAssertTrue(viewModel.transcript.contains { $0.text == "backend output" })
        XCTAssertTrue(session.submittedTexts.isEmpty,
                      "exec output must not be sent to the model")
    }

    func testExtensionCommandRunsOnBackend() async throws {
        let (session, viewModel) = try await makeFixture()
        _ = await viewModel.send("/deploy-check")
        XCTAssertEqual(session.slashBox.executedCommands, ["/deploy-check"],
                       "dynamic quick/plugin commands execute without a Fleet release")
    }

    func testTerminalCommandIsHonestAndNeverExecutes() async throws {
        let (session, viewModel) = try await makeFixture()
        let sent = await viewModel.send("/redraw")
        XCTAssertFalse(sent)
        XCTAssertEqual(
            viewModel.commandSuggestionError,
            "/redraw is available from the Hermes terminal, not Fleet.")
        XCTAssertTrue(session.slashBox.executedCommands.isEmpty)
    }

    // MARK: - Dispatch interpretation

    func testPrefillDirectiveReplacesComposerTextWithoutSubmitting() async throws {
        let (session, viewModel) = try await makeFixture()
        session.slashBox.executeResult = HermesSlashExecution(
            output: nil,
            warning: nil,
            dispatch: .prefill(message: "edited draft", notice: "Backed up 1 turn"))
        let sent = await viewModel.send("/undo")
        XCTAssertTrue(sent)
        XCTAssertEqual(viewModel.prefillText, "edited draft")
        XCTAssertTrue(session.submittedTexts.isEmpty,
                      "prefill must never submit")
    }

    func testSendDirectiveUsesPreparedPathWithDisplayProjection() async throws {
        let (session, viewModel) = try await makeFixture()
        session.slashBox.executeResult = HermesSlashExecution(
            output: nil,
            warning: nil,
            dispatch: .send(
                message: "model-facing text",
                display: "/goal fix the leak",
                notice: "⊙ Goal set"))
        let sent = await viewModel.send("/goal fix the leak")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.submittedTexts, ["model-facing text"])
        XCTAssertTrue(viewModel.transcript.contains { $0.kind == .user && $0.text.contains("/goal fix the leak") },
                      "display projection renders in the user bubble")
        XCTAssertTrue(viewModel.transcript.contains { $0.text == "⊙ Goal set" },
                      "notice renders as a system row")
    }

    func testSkillDirectivePreservesDisplayModelSeparation() async throws {
        let (session, viewModel) = try await makeFixture()
        session.slashBox.executeResult = HermesSlashExecution(
            output: nil,
            warning: nil,
            dispatch: .skill(message: "EXPANDED SCAFFOLD", display: "/work fix"))
        let sent = await viewModel.send("/work fix")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.submittedTexts, ["EXPANDED SCAFFOLD"])
        let userRows = viewModel.transcript.filter { $0.kind == .user }
        XCTAssertEqual(userRows.last?.text, "/work fix")
        XCTAssertFalse(viewModel.transcript.contains { $0.kind == .user && $0.text.contains("EXPANDED") },
                       "expanded scaffolding must never render as the user bubble")
    }

    func testUnknownDispatchTypeFailsClosedNeverChats() async throws {
        let (session, viewModel) = try await makeFixture()
        session.slashBox.executeError = .unknownDispatchType("holodeck")
        let sent = await viewModel.send("/usage")
        XCTAssertTrue(sent, "the command honestly reported its result")
        XCTAssertTrue(session.submittedTexts.isEmpty,
                      "unknown dispatch must never become ordinary chat")
        XCTAssertNotNil(viewModel.commandSuggestionError)
    }

    func testAliasDirectiveRedispatchesSafely() async throws {
        let (session, viewModel) = try await makeFixture()
        session.slashBox.oneShotResult = HermesSlashExecution(
            output: nil,
            warning: nil,
            dispatch: .alias(target: "usage"))
        _ = await viewModel.send("/quick-alias")
        // The alias rerouted into the backend exec path for /usage.
        XCTAssertEqual(session.slashBox.executedCommands, ["/quick-alias", "/usage"])
    }

    // MARK: - Discovery

    func testBareSlashShowsBuiltinsExtensionsAndHidesTerminalAndAliases() async throws {
        let (_, viewModel) = try await makeFixture()
        viewModel.updateSlashSuggestions(for: "/")
        for _ in 0..<200 where viewModel.isLoadingCommandSuggestions {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let texts = viewModel.commandSuggestions.map(\.text)
        XCTAssertTrue(texts.contains("/steer"))
        XCTAssertTrue(texts.contains("/new"))
        XCTAssertTrue(texts.contains("/deploy-check"),
                      "extension commands surface in browsing")
        XCTAssertFalse(texts.contains("/redraw"),
                       "terminal-only commands are excluded from suggestions")
        XCTAssertFalse(texts.contains("/reset"),
                       "aliases are not suggested as duplicate rows")
    }

    func testStaleCommandLeavesComposerEditable() async throws {
        let (session, viewModel) = try await makeFixture()
        session.slashBox.executeError = .commandUnavailable("gone")
        let sent = await viewModel.send("/gone draft text")
        XCTAssertFalse(sent)
        XCTAssertEqual(
            viewModel.commandSuggestionError,
            "/gone is no longer available on this gateway. Refresh and try again.")
        XCTAssertTrue(session.submittedTexts.isEmpty)
    }
}
