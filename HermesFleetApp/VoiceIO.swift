import Foundation
import AVFoundation
import Speech
import FleetCore

/// R10-T4 — the concrete on-device voice engine (Speech framework STT +
/// AVSpeechSynthesizer TTS), injected as the `VoiceTranscribing` seam at the
/// composition root.
///
/// DOCUMENTED DEVIATION (docs/R10): hermes-agent 0.21 exposes NO client-audio
/// WS upload method — `/voice` listens on the GATEWAY'S LOCAL microphone via
/// `full_duplex_listen` (tui_gateway/server.py:17334). The iOS app therefore
/// transcribes on-device and submits TEXT through the normal `prompt.submit`
/// path, and speaks replies locally. No wire was invented.
///
/// Interrupt semantics mirror the gateway's `mark_speech_interrupted`
/// (server.py:17191 / 17303): a new user turn cuts speech immediately.
public final class SpeechVoiceIO: VoiceTranscribing, @unchecked Sendable {

    // All mutable state is guarded by `lock`; async functions touch it ONLY
    // through the synchronous helpers below (NSLock is unavailable from
    // async contexts).
    private let lock = NSLock()
    private var _isSpeaking = false

    // Recognition state.
    private var recognitionContinuation: CheckedContinuation<VoiceTranscript?, Never>?
    private var recognitionEnded = false
    private var captureActive = false
    private var finalTranscript = ""
    private var partialTranscript = ""

    // Synthesis state.
    private let synthesizer = AVSpeechSynthesizer()
    private var pendingTexts: [String] = []
    private var isSynthesizing = false
    private var speechBridge: SpeechCompletionBridge?

    public init() {}

    // MARK: - Sync state helpers (caller-side lock discipline lives HERE)

    /// Begin a capture; false when one is already active.
    private func tryBeginCapture() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if captureActive { return false }
        captureActive = true
        recognitionEnded = false
        finalTranscript = ""
        partialTranscript = ""
        return true
    }

    private func endCapture() {
        lock.lock(); defer { lock.unlock() }
        captureActive = false
    }

    private func isCaptureActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return captureActive
    }

    /// Recognition handler: record a result; resume-on-end when settled.
    private func recordResult(final: Bool, text: String) {
        lock.lock(); defer { lock.unlock() }
        if final {
            finalTranscript = text
        } else {
            partialTranscript = text
        }
    }

    private func recognitionDidEnd() {
        lock.lock(); defer { lock.unlock() }
        resumeOnceLocked()
    }
    /// Manual-stop resume (async-context-safe wrapper).
    private func forceResumeRecognition() {
        lock.lock(); defer { lock.unlock() }
        resumeOnceLocked()
    }
    /// Park: register the continuation, resuming immediately if recognition
    /// already ended (race guard).
    private func parkContinuation(_ continuation: CheckedContinuation<VoiceTranscript?, Never>) {
        lock.lock(); defer { lock.unlock() }
        recognitionContinuation = continuation
        if recognitionEnded {
            resumeOnceLocked()
        }
    }

    /// Resume the parked continuation EXACTLY ONCE. CALLER HOLDS `lock`.
    private func resumeOnceLocked() {
        recognitionEnded = true
        guard let continuation = recognitionContinuation else { return }
        recognitionContinuation = nil
        if !finalTranscript.isEmpty {
            continuation.resume(returning: VoiceTranscript(text: finalTranscript, isFinal: true))
        } else if !partialTranscript.isEmpty {
            continuation.resume(returning: VoiceTranscript(text: partialTranscript, isFinal: false))
        } else {
            continuation.resume(returning: nil)
        }
    }

    /// Enqueue one TTS chunk; returns true when this caller should drain.
    private func enqueueSpeech(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pendingTexts.append(text)
        if isSynthesizing || pendingTexts.count > 1 { return false }
        isSynthesizing = true
        _isSpeaking = true
        return true
    }

    /// Take the next queued chunk; nil when the queue is empty (and drains
    /// the speaking flags).
    private func nextSpeechChunk() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pendingTexts.isEmpty else {
            isSynthesizing = false
            _isSpeaking = false
            return nil
        }
        return pendingTexts.removeFirst()
    }

    /// Cut the queue (interrupt): drop pending chunks.
    private func cutSpeech() {
        lock.lock(); defer { lock.unlock() }
        pendingTexts.removeAll()
        isSynthesizing = false
        _isSpeaking = false
    }

    private func retainBridge(_ bridge: SpeechCompletionBridge) {
        lock.lock(); defer { lock.unlock() }
        speechBridge = bridge // held until the next utterance replaces it
    }

    // MARK: - Authorization

    public func authorizationStatus() async -> VoiceAuthorization {
        mapStatus(
            speech: SFSpeechRecognizer.authorizationStatus(),
            mic: AVAudioSession.sharedInstance().recordPermission
        )
    }

    public func requestAuthorization() async -> VoiceAuthorization {
        // Speech recognition permission (system sheet on first ask).
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        // Microphone permission — asked explicitly so the authorization gate
        // is deterministic (rather than the sheet firing mid-capture).
        let mic: AVAudioSession.RecordPermission
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted, .denied:
            mic = AVAudioSession.sharedInstance().recordPermission
        case .undetermined:
            mic = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            }
        @unknown default:
            mic = .denied
        }
        return mapStatus(speech: speech, mic: mic)
    }

    private func mapStatus(
        speech: SFSpeechRecognizerAuthorizationStatus,
        mic: AVAudioSession.RecordPermission
    ) -> VoiceAuthorization {
        if speech == .notDetermined || mic == .undetermined {
            return .undetermined
        }
        if speech == .authorized && mic == .granted {
            return .authorized
        }
        // Denied or restricted on EITHER surface → honest denied gate.
        return .denied
    }

    // MARK: - Transcription (STT)

    public func transcribe() async throws -> VoiceTranscript? {
        guard tryBeginCapture() else { throw VoiceError.alreadyListening }
        defer { endCapture() }

        let locale = Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            throw VoiceError.captureFailed("audio session: \(Self.nonSecret(error))")
        }
        defer { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep audio on-device when supported (privacy: only the recognized
        // TEXT is ever submitted to the gateway).
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        // The tap block is @Sendable; the request is not Sendable — hand it
        // over inside a box (append is thread-safe per AVFoundation docs).
        let requestBox = RequestBox(request)

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw VoiceError.captureFailed("no audio input route")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            requestBox.request.append(buffer)
        }
        audioEngine.prepare()

        let resultTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            var ended = error != nil
            if let result {
                let best = result.bestTranscription.formattedString
                if !best.isEmpty {
                    self.recordResult(final: result.isFinal, text: best)
                }
                if result.isFinal { ended = true }
            }
            if ended {
                self.recognitionDidEnd()
            }
        }

        do {
            try audioEngine.start()
        } catch {
            request.endAudio()
            resultTask.finish()
            throw VoiceError.captureFailed("audio engine: \(Self.nonSecret(error))")
        }

        // Park until recognition settles (final result / error) or
        // stopTranscribing() fires.
        let transcript = await withCheckedContinuation { (continuation: CheckedContinuation<VoiceTranscript?, Never>) in
            parkContinuation(continuation)
        }

        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request.endAudio()
        resultTask.finish()
        return transcript
    }

    public func stopTranscribing() async {
        guard isCaptureActive() else { return }
        // End-of-audio grace: the recognizer usually flushes a final result
        // shortly after the tap stops arriving; after the window, take the
        // best partial (isFinal == false — review-only upstream, never
        // auto-submitted).
        try? await Task.sleep(for: .milliseconds(600))
        forceResumeRecognition()
    }

    // MARK: - Speech (TTS)

    public func speak(text: String) async throws {
        if enqueueSpeech(text) {
            await drainSpeechQueue()
        }
    }

    private func drainSpeechQueue() async {
        while let next = nextSpeechChunk() {
            let finished = await speakAndWait(next)
            if !finished {
                // Cut by stopSpeaking() — drop the remaining queue.
                cutSpeech()
                return
            }
        }
    }

    /// Speak one chunk; returns false when cut by `stopSpeaking()`.
    private func speakAndWait(_ text: String) async -> Bool {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let bridge = SpeechCompletionBridge { finished in
                continuation.resume(returning: finished)
            }
            retainBridge(bridge)
            synthesizer.delegate = bridge
            synthesizer.speak(utterance)
        }
    }

    public func stopSpeaking() async {
        cutSpeech()
        synthesizer.stopSpeaking(at: .immediate)
    }

    public var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isSpeaking
    }

    private static func nonSecret(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}

/// @Sendable-safe box for handing the recognition request to the audio tap.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

/// Per-utterance completion bridge: resumes EXACTLY once on
/// didFinish (true) or didCancel (false) — the cut signal.
private final class SpeechCompletionBridge: NSObject, AVSpeechSynthesizerDelegate {
    private let lock = NSLock()
    private var resumed = false
    private let onDone: @Sendable (Bool) -> Void

    init(onDone: @escaping @Sendable (Bool) -> Void) {
        self.onDone = onDone
        super.init()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(false)
    }

    private func finish(_ completed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        onDone(completed)
    }
}
