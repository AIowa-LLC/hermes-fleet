import Foundation

/// R10-T4 voice transcript value: the FINAL recognized utterance (or the best
/// partial when the user stopped capture manually).
public struct VoiceTranscript: Equatable, Sendable {
    /// The recognized text (best available at capture end).
    public let text: String
    /// True when recognition settled on its own (silence/end-of-utterance);
    /// false when the user tapped stop and we took the best partial.
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Authorization vocabulary for the two iOS permissions voice needs
/// (microphone + speech recognition). Deliberately coarse: the UI renders an
/// honest denied state and points at Settings; per-permission nuance is not
/// product-visible.
public enum VoiceAuthorization: Equatable, Sendable {
    /// Not yet asked (or the seam cannot tell).
    case undetermined
    /// Granted — listening may start without a prompt.
    case authorized
    /// Denied or restricted — honest gate UI, no prompt.
    case denied
}

/// Typed, non-secret voice failure vocabulary (never silent).
public enum VoiceError: Error, Equatable, Sendable {
    /// The recognizer is unavailable on this device/locale.
    case recognizerUnavailable
    /// Listening was requested while another capture is running.
    case alreadyListening
    /// Capture failed (audio session / recognition error). Detail is
    /// non-secret.
    case captureFailed(String)
    /// The seam has no engine wired (fail-closed default).
    case unsupported

    public var description: String {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is unavailable on this device or locale."
        case .alreadyListening:
            return "Already listening — stop the current capture first."
        case .captureFailed(let detail):
            return "Voice capture failed (\(detail))."
        case .unsupported:
            return "Voice is not available on this screen."
        }
    }
}

/// R10-T4 seam: client-side speech transcription (STT). The iOS app does NOT
/// stream audio to the gateway — hermes-agent 0.21 has no client-audio WS
/// method (`/voice` listens on the GATEWAY's local mic via
/// `full_duplex_listen`, server.py:17334). Transcription therefore happens on
/// the device via the Speech framework and the TEXT is submitted through the
/// normal `prompt.submit` path. Documented deviation (docs/R10).
///
/// Lives in FleetCore so FleetUI never imports AVFoundation/Speech (M0 guard
/// discipline); the concrete `SpeechVoiceIO` is injected at the composition
/// root, tests inject scripted doubles.
public protocol VoiceTranscribing: Sendable {
    /// Current authorization state WITHOUT prompting.
    func authorizationStatus() async -> VoiceAuthorization
    /// Prompt if needed (system sheets). Returns the post-prompt state.
    func requestAuthorization() async -> VoiceAuthorization
    /// Capture audio from the device mic and recognize ONE utterance.
    /// Suspends until recognition settles (final result) or
    /// `stopTranscribing()` is called (best partial). Returns nil when
    /// nothing was recognized.
    func transcribe() async throws -> VoiceTranscript?
    /// Stop an in-flight `transcribe()` — it returns the best partial (or
    /// nil). No-op when idle.
    func stopTranscribing() async
    /// Speak text (TTS). Calls queue as chunks (streaming deltas each enqueue
    /// one utterance); an in-flight utterance is NOT cut by a later `speak`.
    func speak(text: String) async throws
    /// Cut ALL speech immediately — the `mark_speech_interrupted` semantics
    /// (a new user turn interrupts the spoken reply; server.py:17191).
    func stopSpeaking() async
    /// True while an utterance is speaking.
    var isSpeaking: Bool { get }
}

/// Fail-closed default: every call surfaces an honest error instead of
/// pretending (the UnsupportedAttachmentStaging discipline). The view model
/// holds this when the composition root wired no voice engine, and hides the
/// mic affordances entirely.
public struct UnsupportedVoiceTranscriber: VoiceTranscribing {
    public init() {}

    public func authorizationStatus() async -> VoiceAuthorization { .undetermined }
    public func requestAuthorization() async -> VoiceAuthorization { .undetermined }
    public func transcribe() async throws -> VoiceTranscript? { throw VoiceError.unsupported }
    public func stopTranscribing() async {}
    public func speak(text: String) async throws { throw VoiceError.unsupported }
    public func stopSpeaking() async {}
    public var isSpeaking: Bool { false }
}
