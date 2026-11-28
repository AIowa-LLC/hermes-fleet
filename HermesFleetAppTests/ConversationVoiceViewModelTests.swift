import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// R10-T4 — conversation voice-mode unit tests (scripted seams, no live
/// speech, no audio hardware). Covers:
/// - mic start requires authorization (gate fires before any capture),
/// - a scripted transcript lands in `latestVoiceTranscript` for composer
///   review (submit-on-silence OFF → NO auto-submit),
/// - submit-on-silence ON + a FINAL transcript auto-submits the exact text,
/// - a PARTIAL transcript (manual stop) never auto-submits,
/// - voice mode ON speaks assistant deltas + the complete text exactly once,
/// - a new user turn cuts speech (`mark_speech_interrupted` semantics),
/// - voice failures surface the never-silent banner,
/// - the fail-closed default hides the affordances.
@MainActor
final class ConversationVoiceViewModelTests: XCTestCase {

    // MARK: - Scripted voice seam

    /// Thread-safe scripted VoiceTranscribing double (the VM is MainActor;
    /// the protocol is Sendable, calls arrive from anywhere). All state is
    /// guarded by `lock` via SYNCHRONOUS helpers (NSLock is unavailable from
    /// async contexts).
    private final class ScriptedVoice: VoiceTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var _authStatus: VoiceAuthorization = .authorized
        private var _scriptedTranscripts: [VoiceTranscript?] = []
        private var _transcribeError: VoiceError?
        private var _transcribeCalls = 0
        private var _stopTranscribeCalls = 0
        private var _speakCalls: [String] = []
        private var _stopSpeakCalls = 0
        private var _isSpeaking = false

        // Sync helpers (the lock lives ONLY inside these).
        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body()
        }

        var authStatus: VoiceAuthorization {
            get { withLock { _authStatus } }
            set { withLock { _authStatus = newValue } }
        }
        var scriptedTranscripts: [VoiceTranscript?] {
            get { withLock { _scriptedTranscripts } }
            set { withLock { _scriptedTranscripts = newValue } }
        }
        var transcribeError: VoiceError? {
            get { withLock { _transcribeError } }
            set { withLock { _transcribeError = newValue } }
        }
        var transcribeCalls: Int { withLock { _transcribeCalls } }
        var stopTranscribeCalls: Int { withLock { _stopTranscribeCalls } }
        var speakCalls: [String] { withLock { _speakCalls } }
        var stopSpeakCalls: Int { withLock { _stopSpeakCalls } }

        func authorizationStatus() async -> VoiceAuthorization { authStatus }
        func requestAuthorization() async -> VoiceAuthorization { authStatus }
        func transcribe() async throws -> VoiceTranscript? {
            try withLock {
                _transcribeCalls += 1
                if let _transcribeError { throw _transcribeError }
                guard !_scriptedTranscripts.isEmpty else { return nil }
                return _scriptedTranscripts.removeFirst()
            }
        }
        func stopTranscribing() async {
            _ = withLock { _stopTranscribeCalls += 1 }
        }
        func speak(text: String) async throws {
            _ = withLock {
                _speakCalls.append(text)
                _isSpeaking = true
            }
        }
        func stopSpeaking() async {
            _ = withLock {
                _stopSpeakCalls += 1
                _isSpeaking = false
            }
        }
        var isSpeaking: Bool { withLock { _isSpeaking } }
    }

    /// Minimal ConversationSessionProviding double (conversation-only paths
    /// exercised here; replay/history default to empty success).
    private final class ScriptedSession:
        ConversationSessionProviding,
        ConversationProviding,
        ReplayProviding,
        SessionHistoryProviding,
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "workstation")
        var statusValue: GatewayStatus = .online
        var status: GatewayStatus { statusValue }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "MacBook")
        }
        func reauthenticate() async throws {}

        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }

        private let streamPair = AsyncStream<ConversationEvent>.makeStream()
        private let submitLock = NSLock()
        private var _submittedTexts: [String] = []
        var submittedTexts: [String] {
            let lock = submitLock
            lock.lock(); defer { lock.unlock() }
            return _submittedTexts
        }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: "s-1", profileName: "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int? = nil, profile: String? = nil) async throws -> ConversationSession {
            ConversationSession(sessionID: sessionID, profileName: "default")
        }
        private func recordSubmit(_ text: String) {
            submitLock.lock(); defer { submitLock.unlock() }
            _submittedTexts.append(text)
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            recordSubmit(text)
            return PromptSubmission(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult {
            InterruptResult(status: "interrupted")
        }
        var events: AsyncStream<ConversationEvent> { streamPair.0 }
        func push(_ event: ConversationEvent) { streamPair.1.yield(event) }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus.parse(output: "Session ID: \(sessionID)")
        }
    }

    // MARK: - Fixture

    private func makeFixture(
        voice: (any VoiceTranscribing)? = nil
    ) async -> (session: ScriptedSession, voiceSeam: ScriptedVoice, viewModel: ConversationViewModel) {
        let session = ScriptedSession()
        let voiceSeam = voice as? ScriptedVoice ?? ScriptedVoice()
        let cache = try! SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        let viewModel = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: nil,
            statusInterval: .milliseconds(10),
            voice: voice // nil ⇒ the VM's UnsupportedVoiceTranscriber default
        )
        await viewModel.start()
        return (session, voiceSeam, viewModel)
    }

    private func flush() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Authorization gate

    func testMicDeniedSurfacesGateStateAndNeverCaptures() async {
        let voice = ScriptedVoice()
        voice.authStatus = .denied
        let (_, voiceSeam, viewModel) = await makeFixture(voice: voice)
        guard case .ready = viewModel.phase else {
            XCTFail("fixture should be ready, got \(viewModel.phase)")
            return
        }
        await viewModel.toggleMic()
        XCTAssertTrue(viewModel.isVoiceDenied, "denied state must surface for the gate UI")
        XCTAssertNil(viewModel.latestVoiceTranscript)
        XCTAssertEqual(voiceSeam.transcribeCalls, 0, "denied ⇒ no capture attempt")
        XCTAssertFalse(viewModel.isListening)
    }

    func testMicAvailableStartsListeningAndFinalTranscriptLandsForReview() async {
        let voice = ScriptedVoice()
        voice.scriptedTranscripts = [VoiceTranscript(text: "status of the fleet", isFinal: true)]
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isSubmitOnSilenceEnabled = false
        await viewModel.toggleMic()
        XCTAssertTrue(viewModel.isListening, "authorized mic starts listening")
        // Capture runs async; let it settle.
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isListening && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(viewModel.isListening)
        XCTAssertEqual(viewModel.latestVoiceTranscript?.text, "status of the fleet")
        XCTAssertEqual(session.submittedTexts, [], "review-first: transcript lands for review, NOT auto-submitted")
    }

    func testSubmitOnSilenceAutoSubmitsFinalTranscriptOnly() async {
        let voice = ScriptedVoice()
        voice.scriptedTranscripts = [VoiceTranscript(text: "run diagnostics", isFinal: true)]
        let (session, _, viewModel) = await makeFixture(voice: voice)
        viewModel.isSubmitOnSilenceEnabled = true
        await viewModel.toggleMic()
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isListening && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(session.submittedTexts, ["run diagnostics"], "final + submit-on-silence ⇒ exact auto-submit")
    }

    func testPartialTranscriptNeverAutoSubmits() async {
        let voice = ScriptedVoice()
        voice.scriptedTranscripts = [VoiceTranscript(text: "run diag", isFinal: false)]
        let (session, _, viewModel) = await makeFixture(voice: voice)
        viewModel.isSubmitOnSilenceEnabled = true
        await viewModel.toggleMic()
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isListening && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(viewModel.latestVoiceTranscript?.text, "run diag")
        XCTAssertEqual(session.submittedTexts, [], "partial (manual stop) never auto-submits")
    }

    // MARK: - TTS

    func testVoiceModeSpeaksWholeReplyExactlyOnceWhenNoSentenceEnded() async {
        let voice = ScriptedVoice()
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isVoiceModeEnabled = true
        await viewModel.send("hi")
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "Hello ", rendered: nil))
        session.push(.messageDelta(sessionID: "s-1", text: "fleet", rendered: nil))
        session.push(.messageComplete(sessionID: "s-1", text: "Hello fleet", status: nil, error: nil))
        await flush()
        // Word fragments are never spoken on their own: the reply is spoken
        // once, as a whole phrase, when it completes.
        XCTAssertEqual(voiceSeam.speakCalls, ["Hello fleet"])
    }

    func testVoiceModeSpeaksStreamedSentencesThenTailExactlyOnce() async {
        let voice = ScriptedVoice()
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isVoiceModeEnabled = true
        await viewModel.send("hi")
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "All four gate", rendered: nil))
        session.push(.messageDelta(sessionID: "s-1", text: "ways are up. Two bots", rendered: nil))
        session.push(.messageDelta(sessionID: "s-1", text: " are busy", rendered: nil))
        session.push(.messageComplete(
            sessionID: "s-1", text: "All four gateways are up. Two bots are busy",
            status: nil, error: nil))
        await flush()
        XCTAssertEqual(voiceSeam.speakCalls, ["All four gateways are up.", "Two bots are busy"])
    }

    func testVoiceModeNeverSpeaksMarkdownOrCode() async {
        let voice = ScriptedVoice()
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isVoiceModeEnabled = true
        await viewModel.send("hi")
        session.push(.messageComplete(
            sessionID: "s-1",
            text: "**Done.** Run this:\n```\nhermes fleet pair\n```\nThen check [the docs](https://example.test/docs).",
            status: nil, error: nil))
        await flush()
        let spoken = voiceSeam.speakCalls.joined(separator: " ")
        XCTAssertFalse(spoken.contains("*"), "spoke: \(spoken)")
        XCTAssertFalse(spoken.contains("`"), "spoke: \(spoken)")
        XCTAssertFalse(spoken.contains("hermes fleet pair"), "code blocks are not read aloud: \(spoken)")
        XCTAssertFalse(spoken.contains("https"), "URLs are not read aloud: \(spoken)")
        XCTAssertTrue(spoken.contains("Done."), "spoke: \(spoken)")
        XCTAssertTrue(spoken.contains("the docs"), "spoke: \(spoken)")
    }

    func testNewUserTurnCutsSpeech() async {
        let voice = ScriptedVoice()
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isVoiceModeEnabled = true
        await viewModel.send("first")
        session.push(.messageComplete(sessionID: "s-1", text: "long spoken reply", status: nil, error: nil))
        await flush()
        XCTAssertEqual(voiceSeam.speakCalls.count, 1)
        // EVERY send cuts speech at entry (mark_speech_interrupted
        // semantics) — the second send interrupts the spoken reply.
        await viewModel.send("second")
        XCTAssertEqual(voiceSeam.stopSpeakCalls, 2, "each user turn cuts speech (both sends cut)")
        XCTAssertEqual(voiceSeam.speakCalls.count, 1, "no additional speak after the cut")
    }

    func testVoiceOffNeverSpeaks() async {
        let voice = ScriptedVoice()
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        await viewModel.send("hi")
        session.push(.messageComplete(sessionID: "s-1", text: "silent reply", status: nil, error: nil))
        await flush()
        XCTAssertEqual(voiceSeam.speakCalls, [], "voice mode OFF ⇒ never speaks")
        XCTAssertEqual(voiceSeam.stopSpeakCalls, 0)
    }

    // MARK: - Hands-free voice mode

    private func waitUntil(
        _ condition: @MainActor () -> Bool, timeout: TimeInterval = 3
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testHandsFreeSendsWhatItHearsSpeaksReplyThenListensAgain() async {
        let voice = ScriptedVoice()
        voice.scriptedTranscripts = [VoiceTranscript(text: "how is the fleet", isFinal: true)]
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)

        await viewModel.startHandsFree()
        XCTAssertTrue(viewModel.isHandsFreeActive)
        XCTAssertTrue(viewModel.isVoiceModeEnabled, "hands-free speaks replies")
        await waitUntil { session.submittedTexts == ["how is the fleet"] }
        XCTAssertEqual(session.submittedTexts, ["how is the fleet"], "heard text is sent without review")
        XCTAssertEqual(viewModel.handsFreePhase, .thinking)

        // The scripted engine hears nothing next, so make the second listen
        // observable before the reply lands.
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "All good. ", rendered: nil))
        session.push(.messageComplete(sessionID: "s-1", text: "All good.", status: nil, error: nil))
        await waitUntil { voiceSeam.transcribeCalls >= 2 }
        XCTAssertEqual(voiceSeam.speakCalls, ["All good."])
        XCTAssertGreaterThanOrEqual(voiceSeam.transcribeCalls, 2, "listens again after speaking")
        await viewModel.endHandsFree()
    }

    func testHandsFreePausesAfterRepeatedSilenceAndSaysWhy() async {
        let voice = ScriptedVoice() // no scripted transcripts: hears nothing
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)

        await viewModel.startHandsFree()
        await waitUntil { !viewModel.isHandsFreeActive }
        XCTAssertFalse(viewModel.isHandsFreeActive)
        XCTAssertEqual(voiceSeam.transcribeCalls, ConversationViewModel.handsFreeSilenceLimit)
        XCTAssertEqual(session.submittedTexts, [])
        XCTAssertNotNil(viewModel.voiceError, "pausing is never silent")
        XCTAssertFalse(viewModel.isVoiceModeEnabled, "reply speech restored to its earlier setting")
    }

    func testEndingHandsFreeRestoresReplySpeechSetting() async {
        let voice = ScriptedVoice()
        voice.scriptedTranscripts = [VoiceTranscript(text: "status", isFinal: true)]
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isVoiceModeEnabled = true

        await viewModel.startHandsFree()
        await waitUntil { session.submittedTexts == ["status"] }
        await viewModel.endHandsFree()
        XCTAssertFalse(viewModel.isHandsFreeActive)
        XCTAssertEqual(viewModel.handsFreePhase, .off)
        XCTAssertTrue(viewModel.isVoiceModeEnabled, "was on before hands-free, stays on")
        XCTAssertGreaterThanOrEqual(voiceSeam.stopSpeakCalls, 1, "ending cuts any speech")
    }

    func testHandsFreeTapWhileSpeakingCutsReplyAndListens() async {
        let voice = ScriptedVoice()
        voice.scriptedTranscripts = [
            VoiceTranscript(text: "tell me a story", isFinal: true),
            VoiceTranscript(text: "stop", isFinal: true),
        ]
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)

        await viewModel.startHandsFree()
        await waitUntil { session.submittedTexts == ["tell me a story"] }
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "Once upon a time. ", rendered: nil))
        await waitUntil { viewModel.handsFreePhase == .speaking }
        XCTAssertEqual(viewModel.handsFreePhase, .speaking)

        let cutsBefore = voiceSeam.stopSpeakCalls
        await viewModel.handsFreeTap()
        XCTAssertGreaterThan(voiceSeam.stopSpeakCalls, cutsBefore, "tap cuts the spoken reply")
        await waitUntil { voiceSeam.transcribeCalls >= 2 }
        XCTAssertGreaterThanOrEqual(voiceSeam.transcribeCalls, 2, "tap starts listening right away")
        await viewModel.endHandsFree()
    }

    func testHandsFreeNeedsAnEngineAndSaysSo() async {
        let (_, _, viewModel) = await makeFixture(voice: nil)
        await viewModel.startHandsFree()
        XCTAssertFalse(viewModel.isHandsFreeActive)
        XCTAssertEqual(viewModel.voiceError, VoiceError.unsupported.description)
    }

    func testHandsFreeDeniedNeverListens() async {
        let voice = ScriptedVoice()
        voice.authStatus = .denied
        let (_, voiceSeam, viewModel) = await makeFixture(voice: voice)
        await viewModel.startHandsFree()
        XCTAssertFalse(viewModel.isHandsFreeActive)
        XCTAssertTrue(viewModel.isVoiceDenied)
        XCTAssertEqual(voiceSeam.transcribeCalls, 0)
    }

    // MARK: - Failures / fail-closed

    func testCaptureFailureSurfacesBannerNeverSilent() async {
        let voice = ScriptedVoice()
        voice.transcribeError = .captureFailed("audio session error")
        let (_, _, viewModel) = await makeFixture(voice: voice)
        await viewModel.toggleMic()
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isListening && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(viewModel.voiceError, "capture failure must surface")
        XCTAssertTrue(viewModel.voiceError?.contains("audio session error") == true)
    }

    func testFailClosedDefaultHidesAffordances() async {
        let (_, _, viewModel) = await makeFixture(voice: nil)
        // No engine wired: UnsupportedVoiceTranscriber default.
        XCTAssertFalse(viewModel.isVoiceAvailable, "no engine ⇒ affordances hidden")
        XCTAssertFalse(viewModel.isListening)
        await viewModel.toggleMic() // no crash, honest error
        let deadline = Date().addingTimeInterval(1)
        while viewModel.voiceError == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(viewModel.voiceError)
    }

    func testEnablingReplySpeechWithoutEngineExplainsWhyItStayedOff() async {
        let (_, _, viewModel) = await makeFixture(voice: nil)

        await viewModel.setVoiceMode(true)

        XCTAssertFalse(viewModel.isVoiceModeEnabled)
        XCTAssertEqual(viewModel.voiceError, VoiceError.unsupported.description)
    }
}
