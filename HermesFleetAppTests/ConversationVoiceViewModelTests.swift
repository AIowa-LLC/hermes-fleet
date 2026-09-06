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
        func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
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

    func testVoiceModeSpeaksDeltasAndCompleteExactlyOnce() async {
        let voice = ScriptedVoice()
        let (session, voiceSeam, viewModel) = await makeFixture(voice: voice)
        viewModel.isVoiceModeEnabled = true
        await viewModel.send("hi")
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "Hello ", rendered: nil))
        session.push(.messageDelta(sessionID: "s-1", text: "fleet", rendered: nil))
        session.push(.messageComplete(sessionID: "s-1", text: "Hello fleet", status: nil, error: nil))
        await flush()
        // Chunked speak: both deltas spoken; the complete text (a duplicate of
        // the concatenated deltas) must NOT be spoken again.
        XCTAssertEqual(voiceSeam.speakCalls, ["Hello ", "fleet"])
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
}
