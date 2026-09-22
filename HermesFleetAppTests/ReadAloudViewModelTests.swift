import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// Stage 1 — read-aloud view-model tests through the EXISTING R10 voice
/// seam (scripted engine; no audio hardware). Pins:
/// - readReplyAloud speaks the exact completed reply text once,
/// - re-tapping the same row toggles OFF (stop + drain),
/// - tapping a different row cuts the previous utterance first
///   (mark_speech_interrupted semantics),
/// - stopReadingReply cuts speech and clears the reading row,
/// - the fail-closed default engine reports voiceCanSpeakFooter == false
///   (the footer renders no ellipsis without a real engine).
@MainActor
final class ReadAloudViewModelTests: XCTestCase {

    /// Thread-safe scripted VoiceTranscribing double.
    private final class ScriptedFooterVoice: VoiceTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var _speakCalls: [String] = []
        private var _stopCalls = 0
        private var _isSpeaking = false

        var speakCalls: [String] { lock.withLock { _speakCalls } }
        var stopCalls: Int { lock.withLock { _stopCalls } }

        func setSpeaking(_ speaking: Bool) { lock.withLock { _isSpeaking = speaking } }

        func authorizationStatus() async -> VoiceAuthorization { .authorized }
        func requestAuthorization() async -> VoiceAuthorization { .authorized }
        func transcribe() async throws -> VoiceTranscript? { nil }
        func stopTranscribing() async {}
        func speak(text: String) async throws {
            lock.withLock {
                _speakCalls.append(text)
                _isSpeaking = true
            }
        }
        func stopSpeaking() async {
            lock.withLock {
                _stopCalls += 1
                _isSpeaking = false
            }
        }
        var isSpeaking: Bool { lock.withLock { _isSpeaking } }
    }

    private func makeViewModel(voice: (any VoiceTranscribing)? = nil) async throws -> ConversationViewModel {
        let session = FooterSessionDouble()
        let cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let viewModel = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: "s-footer",
            statusInterval: .milliseconds(10),
            voice: voice)
        await viewModel.start()
        return viewModel
    }

    /// Minimal session double — only the open path the VM needs (mirrors the
    /// MessageReactionsViewModelTests fixture shape).
    private final class FooterSessionDouble: ConversationSessionProviding, @unchecked Sendable {
        let gatewayID = GatewayID(rawValue: "workstation")
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: false, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "MacBook") }
        func reauthenticate() async throws {}
        var conversation: any ConversationProviding { ConversationDouble() }
        var replay: any ReplayProviding { ReplayDouble() }
        var history: any SessionHistoryProviding { HistoryDouble() }

        fileprivate final class ConversationDouble: ConversationProviding, @unchecked Sendable {
            func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
                ConversationSession(sessionID: "s-footer", profileName: "default")
            }
            func resumeSession(sessionID: String, lastEventID: Int? = nil, profile: String? = nil) async throws -> ConversationSession {
                ConversationSession(sessionID: sessionID, profileName: "default")
            }
            func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
                PromptSubmission(status: "streaming")
            }
            func interrupt(sessionID: String) async throws -> InterruptResult {
                InterruptResult(status: "interrupted")
            }
            var events: AsyncStream<ConversationEvent> { AsyncStream { _ in } }
            func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        }
        private struct ReplayDouble: ReplayProviding {
            let gatewayID = GatewayID(rawValue: "workstation")
            func watermarks() async -> [SessionEventWatermark] { [] }
            func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        }
        private struct HistoryDouble: SessionHistoryProviding {
            func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
                SessionHistory(sessionID: sessionID, count: 0, messages: [])
            }
            func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
                SessionStatus.parse(output: "Session ID: \(sessionID)")
            }
        }
    }

    // MARK: - Tests

    /// speak() rides the SpeechQueue actor — a bounded ASYNC poll until the
    /// expected count lands (never Thread.sleep: blocking the main actor
    /// starves the very task under test).
    private func waitForSpeaks(_ voice: ScriptedFooterVoice, count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while voice.speakCalls.count < count && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(voice.speakCalls.count, count, "spoke: \(voice.speakCalls)", file: file, line: line)
    }

    func testReadReplyAloudSpeaksExactTextOnce() async throws {
        let voice = ScriptedFooterVoice()
        let viewModel = try await makeViewModel(voice: voice)

        let spoke = await viewModel.readReplyAloud(rowID: "r1", text: "The summary is ready.")
        XCTAssertTrue(spoke)
        await waitForSpeaks(voice, count: 1)
        XCTAssertEqual(voice.speakCalls, ["The summary is ready."])
        XCTAssertEqual(viewModel.readAloudRowID, "r1")
    }

    func testNaturalCompletionClearsReadAloudState() async throws {
        let voice = ScriptedFooterVoice()
        let viewModel = try await makeViewModel(voice: voice)

        _ = await viewModel.readReplyAloud(rowID: "r1", text: "finished reply")
        XCTAssertEqual(viewModel.readAloudRowID, "r1")
        voice.setSpeaking(false)
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertNil(viewModel.readAloudRowID,
                     "footer state must clear when the shared speech engine finishes naturally")
    }

    func testReTapSameRowTogglesOff() async throws {
        let voice = ScriptedFooterVoice()
        let viewModel = try await makeViewModel(voice: voice)

        _ = await viewModel.readReplyAloud(rowID: "r1", text: "first reply")
        await waitForSpeaks(voice, count: 1)
        _ = await viewModel.readReplyAloud(rowID: "r1", text: "first reply")

        XCTAssertEqual(voice.speakCalls, ["first reply"], "second tap must NOT re-speak")
        // The implementation avoids a spurious stop on a first tap; the
        // toggle-off stop is the only cut.
        XCTAssertEqual(voice.stopCalls, 1, "toggle-off cuts the utterance")
        XCTAssertNil(viewModel.readAloudRowID)
    }

    func testDifferentRowCutsPreviousUtterance() async throws {
        let voice = ScriptedFooterVoice()
        let viewModel = try await makeViewModel(voice: voice)

        _ = await viewModel.readReplyAloud(rowID: "r1", text: "one")
        await waitForSpeaks(voice, count: 1)
        _ = await viewModel.readReplyAloud(rowID: "r2", text: "two")
        await waitForSpeaks(voice, count: 2)

        XCTAssertEqual(voice.speakCalls, ["one", "two"])
        // One cut: replacing "one" with "two" (no spurious first-tap stop).
        XCTAssertEqual(voice.stopCalls, 1, "the old utterance is cut before the new one")
        XCTAssertEqual(viewModel.readAloudRowID, "r2")
    }

    func testStopReadingReplyClearsState() async throws {
        let voice = ScriptedFooterVoice()
        let viewModel = try await makeViewModel(voice: voice)

        _ = await viewModel.readReplyAloud(rowID: "r1", text: "spoken")
        await waitForSpeaks(voice, count: 1)
        await viewModel.stopReadingReply()

        // No spurious first-tap stop; the explicit stop is the only cut.
        XCTAssertEqual(voice.stopCalls, 1)
        XCTAssertNil(viewModel.readAloudRowID)
    }

    func testEmptyTextNeverSpeaks() async throws {
        let voice = ScriptedFooterVoice()
        let viewModel = try await makeViewModel(voice: voice)

        let spoke = await viewModel.readReplyAloud(rowID: "r1", text: "   ")
        XCTAssertFalse(spoke)
        XCTAssertTrue(voice.speakCalls.isEmpty)
    }

    func testFailClosedEngineHidesReadAloud() async throws {
        // No voice injected → UnsupportedVoiceTranscriber default.
        let viewModel = try await makeViewModel(voice: nil)

        XCTAssertFalse(viewModel.voiceCanSpeakFooter, "fail-closed default must hide the footer ellipsis")
        let spoke = await viewModel.readReplyAloud(rowID: "r1", text: "unreachable")
        XCTAssertFalse(spoke)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
