import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// Card E — the image-generation animation lifecycle in the conversation VM,
/// plus source-level wiring guards for the pieces a unit test cannot reach.
///
/// Hermetic coverage of:
/// - a verified `image_generate` frame starts the branded animation on the
///   citing tool row (and ONLY that row);
/// - the tool's result delivers it, an explicit failure stops it;
/// - a turn error / turn end / interrupt / transport drop stops it — the
///   animation never outlives the work it claims;
/// - replayed frames never resurrect a finished generation.
@MainActor
final class ImageGenerationAnimationViewModelTests: XCTestCase {

    private let gateway = GatewayID(rawValue: "workstation")
    private var route: Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: "default"))
    }

    // MARK: - Harness

    private func makeViewModel(session: ScriptedSession) -> ConversationViewModel {
        ConversationViewModel(
            session: session,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            route: route,
            sessionID: nil,
            statusInterval: .milliseconds(10))
    }

    private func flush(_ milliseconds: Int = 60) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func toolRow(_ model: ConversationViewModel) -> ConversationRow? {
        model.transcript.first { $0.kind == .tool }
    }

    private func generationStart(toolID: String = "t-img") -> ConversationEvent {
        .toolStart(sessionID: "s-1", toolID: toolID, name: "image_generate", context: "draw a cat", argsText: nil)
    }

    private func generationComplete(toolID: String = "t-img", result: String? = #"{"success": true, "image": "/home/u/.hermes/cache/images/generated_1.png"}"#) -> ConversationEvent {
        .toolComplete(sessionID: "s-1", toolID: toolID, name: "image_generate", summary: nil, resultText: result)
    }

    // MARK: - Verified start

    func testVerifiedStartBeginsTheAnimationOnTheCitingRow() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        await flush()

        XCTAssertEqual(toolRow(model)?.generationActivity, .generating(toolID: "t-img"))
        XCTAssertTrue(model.transcript.filter { $0.kind == .tool }.count == 1,
                      "tool.generating-less start mints exactly one chip")
    }

    func testToolGeneratingBeforeToolStartStillBegins() async {
        // P0-8 live order: tool.generating (no id) precedes tool.start.
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(.toolGenerating(sessionID: "s-1", name: "image_generate"))
        session.push(generationStart())
        await flush()

        let rows = model.transcript.filter { $0.kind == .tool }
        XCTAssertEqual(rows.count, 1, "the placeholder row is adopted, never duplicated")
        XCTAssertEqual(rows.first?.generationActivity, .generating(toolID: "t-img"))
    }

    func testOtherToolsNeverBeginTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(.toolStart(sessionID: "s-1", toolID: "t1", name: "web_search", context: "cats", argsText: nil))
        session.push(.toolComplete(sessionID: "s-1", toolID: "t1", name: "web_search", summary: "3 results"))
        await flush()

        XCTAssertNil(toolRow(model)?.generationActivity, "a non-generation tool never carries the animation state")
    }

    // MARK: - Delivery + failure

    func testCompletionDeliversAndHandsOffToTheArtifact() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        session.push(generationComplete())
        await flush()

        let row = toolRow(model)
        XCTAssertEqual(row?.generationActivity, .delivered(toolID: "t-img"))
        XCTAssertEqual(row?.artifacts?.count, 1, "the delivered image takes over the slot")
    }

    func testExplicitFailureStopsTheAnimationWithoutAnArtifact() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        session.push(generationComplete(result: #"{"success": false, "error": "boom"}"#))
        await flush()

        let row = toolRow(model)
        XCTAssertEqual(row?.generationActivity, .stopped(toolID: "t-img", reason: .failed))
        XCTAssertNil(row?.artifacts)
    }

    // MARK: - Stops

    func testTurnErrorStopsTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        session.push(.messageComplete(sessionID: "s-1", text: "", status: "error", error: "provider down"))
        await flush()

        XCTAssertEqual(toolRow(model)?.generationActivity, .stopped(toolID: "t-img", reason: .failed))
    }

    func testTurnEndWithoutAResultStopsTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageComplete(sessionID: "s-1", text: "done", status: nil, error: nil))
        await flush()

        XCTAssertEqual(toolRow(model)?.generationActivity, .stopped(toolID: "t-img", reason: .cancelled))
    }

    func testTurnLevelErrorEventStopsTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        session.push(.error(sessionID: "s-1", message: "stream died"))
        await flush()

        XCTAssertEqual(toolRow(model)?.generationActivity, .stopped(toolID: "t-img", reason: .failed))
    }

    func testInterruptStopsTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(.messageStart(sessionID: "s-1"))
        session.push(generationStart())
        await flush()
        XCTAssertEqual(toolRow(model)?.generationActivity, .generating(toolID: "t-img"),
                       "precondition: the generation is in flight before the interrupt")

        await model.interrupt()
        await flush()

        XCTAssertEqual(toolRow(model)?.generationActivity, .stopped(toolID: "t-img", reason: .cancelled))
    }

    func testTransportDropStopsTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart())
        await flush()
        XCTAssertEqual(toolRow(model)?.generationActivity, .generating(toolID: "t-img"))

        session.statusValue = .offline
        await flush(200)

        XCTAssertEqual(toolRow(model)?.generationActivity, .stopped(toolID: "t-img", reason: .disconnected))
    }

    // MARK: - Replay safety

    func testReplayedFramesNeverResurrectAFinishedGeneration() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        let frames: [ConversationEvent] = [
            .toolGenerating(sessionID: "s-1", name: "image_generate"),
            generationStart(),
            generationComplete(),
        ]
        for frame in frames { session.push(frame) }
        await flush()

        // Reconnect/replay: the same frames arrive again.
        for frame in frames { session.push(frame) }
        await flush()

        let row = toolRow(model)
        XCTAssertEqual(row?.generationActivity, .delivered(toolID: "t-img"),
                       "a replayed start frame must not re-animate a finished generation")
        XCTAssertEqual(row?.artifacts?.count, 1)
    }

    func testANewCallOnTheSameRowRestartsTheAnimation() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(generationStart(toolID: "t-img-1"))
        session.push(generationComplete(toolID: "t-img-1"))
        await flush()

        // A second generation in the same turn mints a NEW tool id — proof of
        // a new call, so the animation re-enters (and re-hands-off).
        session.push(generationStart(toolID: "t-img-2"))
        await flush()
        XCTAssertEqual(toolRow(model)?.generationActivity, .generating(toolID: "t-img-2"))

        session.push(generationComplete(toolID: "t-img-2", result: #"{"success": true, "image": "/home/u/.hermes/cache/images/generated_2.png"}"#))
        await flush()
        XCTAssertEqual(toolRow(model)?.generationActivity, .delivered(toolID: "t-img-2"))
        XCTAssertEqual(toolRow(model)?.artifacts?.count, 2, "both cited images stay on the row")
    }

    // MARK: - Scripted session double

    private final class ScriptedSession:
        ConversationSessionProviding,
        ConversationProviding,
        ReplayProviding,
        SessionHistoryProviding,
        @unchecked Sendable
    {
        let gatewayID: GatewayID
        var statusValue: GatewayStatus = .online
        var interruptResult: InterruptResult = InterruptResult(status: "interrupted")
        private let streamPair: (AsyncStream<ConversationEvent>, AsyncStream<ConversationEvent>.Continuation)

        init(gatewayID: GatewayID) {
            self.gatewayID = gatewayID
            self.streamPair = AsyncStream.makeStream()
        }

        func push(_ event: ConversationEvent) {
            streamPair.1.yield(event)
        }

        // GatewayConnectivityProviding
        var status: GatewayStatus { statusValue }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "Workstation")
        }

        // ConversationSessionProviding
        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }
        func reauthenticate() async throws {}

        // ConversationProviding
        var events: AsyncStream<ConversationEvent> { streamPair.0 }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: "s-1", profileName: "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: sessionID, profileName: "default")
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            PromptSubmission(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult { interruptResult }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }

        // ReplayProviding
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }

        // SessionHistoryProviding
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus(rawOutput: "ok")
        }
    }
}

/// Card E — SOURCE-LEVEL wiring guards for the animation render site and the
/// view implementation (what a pure unit test cannot reach: the SwiftUI call
/// sites and the deliberate absence of determinate progress).
final class ImageGenerationAnimationWiringGuardTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HermesFleetAppTests/
        .deletingLastPathComponent() // repo root

    private func source(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var wingViewPath: String { "Packages/FleetUI/Sources/FleetUI/FleetWingGenerationView.swift" }
    private var conversationPath: String { "Packages/FleetUI/Sources/FleetUI/ConversationView.swift" }

    /// Indeterminate by construction: no percentage formatting, no
    /// determinate progress control, no timer-driven refresh anywhere in the
    /// animation view (card E: no fabricated %/ETA).
    func testWingAnimationViewCarriesNoDeterminateProgress() throws {
        let source = try source(wingViewPath)
        XCTAssertFalse(source.contains("%"), "the animation must never render a percentage")
        XCTAssertFalse(source.contains("ProgressView"), "no determinate (or indeterminate) system spinner — the wing IS the indicator")
        XCTAssertFalse(source.contains("TimelineView"), "no continuous timeline redraw (battery + XCUITest determinism)")
    }

    /// Reduce Motion is honored by ROUTING through the pure rule (so the
    /// decision is unit-tested, not re-derived at the call site).
    func testWingAnimationRoutesReduceMotionThroughTheRule() throws {
        let source = try source(wingViewPath)
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"),
                      "the view must read the Reduce Motion accessibility setting")
        XCTAssertTrue(source.contains("ImageGenerationRules.motion(reduceMotion: reduceMotion)"),
                      "the motion decision must come from ImageGenerationRules.motion")
    }

    /// The visible copy + the accessibility semantics live in FleetCore
    /// (`ImageGenerationCopy`), never duplicated as literals in the view.
    func testWingAnimationUsesTheCoreCopy() throws {
        let source = try source(wingViewPath)
        XCTAssertTrue(source.contains("ImageGenerationCopy.caption"))
        XCTAssertTrue(source.contains("ImageGenerationCopy.detail"))
        XCTAssertTrue(source.contains("ImageGenerationCopy.accessibilityLabel"))
        XCTAssertTrue(source.contains("ImageGenerationCopy.accessibilityValue"))
        XCTAssertFalse(source.contains("\"Generating image…\""),
                       "the caption literal belongs to FleetCore, not the view")
    }

    /// The transcript renders the animation ONLY for a verified in-flight
    /// state, and its insertion/removal is Reduce-Motion gated.
    func testTranscriptRendersTheAnimationOnlyForGeneratingRows() throws {
        let source = try source(conversationPath)
        XCTAssertTrue(source.contains("row.generationActivity?.isGenerating == true"),
                      "only a verified .generating row may render the animation")
        XCTAssertTrue(source.contains("FleetWingGenerationView(identifier: row.id)"),
                      "the animation must render in the row that cited the generation")
        XCTAssertTrue(source.contains("reduceMotion ? .identity"),
                      "the lifecycle swap must collapse to no motion under Reduce Motion")
    }

    /// The four stop paths are all present in the VM (turn end / failure,
    /// turn-level error, interrupt, transport drop).
    func testViewModelStopsTheAnimationOnEveryTerminalPath() throws {
        let source = try source("Packages/FleetUI/Sources/FleetUI/ConversationViewModel.swift")
        for stop in [
            "stopInFlightImageGenerations(reason: isError ? .failed : .cancelled)",
            "stopInFlightImageGenerations(reason: .failed)",
            "stopInFlightImageGenerations(reason: .cancelled)",
            "stopInFlightImageGenerations(reason: .disconnected)",
        ] {
            XCTAssertTrue(source.contains(stop), "missing stop path: \(stop)")
        }
        XCTAssertTrue(source.contains("ImageGenerationRules.transition("),
                      "frame routing must go through the pure lifecycle rule")
    }

    /// The scripted demo keeps the E knobs (hold + failure + order), and card
    /// D's immediate-complete, tools-first flow stays the default.
    func testScriptedDemoKeepsTheAnimationKnobs() throws {
        let source = try source("HermesFleetApp/FleetSimulator.swift")
        XCTAssertTrue(source.contains("HERMES_FLEET_IMAGE_DEMO_HOLD_MS"),
                      "the hold knob is what makes the in-flight state observable")
        XCTAssertTrue(source.contains("HERMES_FLEET_IMAGE_DEMO_FAIL"),
                      "the failure knob drives the stop-path UI journey")
        XCTAssertTrue(source.contains("HERMES_FLEET_IMAGE_DEMO_ORDER"),
                      "the order knob mirrors the second real wire shape (tool mid-stream)")
    }
}
