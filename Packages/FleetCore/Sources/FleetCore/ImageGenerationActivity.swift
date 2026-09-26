import Foundation

/// Card E — the in-flight lifecycle of one `image_generate` tool call.
///
/// The transcript's honesty rule applies to motion too: nothing is invented.
/// A generation enters `generating` ONLY from a wire frame that names the
/// `image_generate` tool (a `tool.start` / `tool.generating` / named
/// `tool.progress` frame — never assistant prose, never a positional guess),
/// and it leaves `generating` only on a terminal frame (the tool's result, a
/// turn-level failure) or a VM-verified stop (the user interrupted the turn,
/// the transport dropped). The animation is therefore a claim the app can
/// back with evidence, and it can never spin for work nobody verified.
public enum ImageGenerationActivity: Equatable, Sendable {
    /// A verified generation frame arrived; no result yet.
    case generating(toolID: String?)
    /// The tool reported a result. The call ended — the row shows the cited
    /// artifact if the result named one, else its normal tool chip.
    case delivered(toolID: String?)
    /// The call ended without a result; the animation must stop.
    case stopped(toolID: String?, reason: ImageGenerationStop)

    /// Whether the branded indeterminate animation renders for this state.
    public var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    /// Whether the call can no longer produce a result frame.
    public var isTerminal: Bool { !isGenerating }

    /// The gateway tool id this state is anchored to (nil while only an
    /// id-less frame — `tool.generating` — has been seen for the call).
    public var toolID: String? {
        switch self {
        case .generating(let toolID), .delivered(let toolID), .stopped(let toolID, _):
            return toolID
        }
    }
}

/// Why a generation ended without a result (card E: the animation stops on
/// failure AND on cancellation; the reason is provenance for tests and any
/// future copy, not a user-facing verdict of its own).
public enum ImageGenerationStop: Equatable, Sendable {
    /// The generation (or its turn) reported a failure.
    case failed
    /// The call ended before its result: the user interrupted the turn, or
    /// the turn settled without the tool ever reporting.
    case cancelled
    /// The transport dropped before the result arrived.
    case disconnected
}

/// Pure lifecycle rules for the generation animation. Deterministic and
/// transport-free so the same rules drive the transcript, the animation and
/// the tests.
public enum ImageGenerationRules {

    /// The tool whose lifecycle the animation tracks (card D's citation
    /// tool — one source for both, so they can never drift).
    public static let toolName = GeneratedImageRules.toolName

    // MARK: Frame transitions

    /// The activity transition caused by one conversation frame, or nil when
    /// the frame says nothing about this row's generation (no state change).
    public static func transition(
        current: ImageGenerationActivity?,
        event: ConversationEvent
    ) -> ImageGenerationActivity? {
        switch event {
        case .toolStart(_, let toolID, let name, _, _, _):
            return started(current: current, name: name, toolID: toolID)
        case .toolGenerating(_, let name, _):
            // On the live wire `tool.generating` can precede `tool.start`
            // (P0-8 probe seq 66 vs 68) — it verifies a generation by name
            // even though it carries no tool id.
            return started(current: current, name: name, toolID: nil)
        case .toolProgress(_, let toolID, let name, _, _):
            // Only a NAMED frame verifies the tool: an anonymous progress
            // frame cannot prove it belongs to a generation (any tool could
            // emit it), so it never starts or extends the animation.
            return started(current: current, name: name, toolID: toolID)
        case .toolComplete(_, let toolID, let name, _, let resultText, _):
            guard name == toolName else { return nil }
            if case .generating(let inFlight) = current,
               let inFlight, inFlight != toolID {
                // A DIFFERENT call's completion never ends this one.
                return nil
            }
            return resultIndicatesFailure(resultText)
                ? .stopped(toolID: toolID, reason: .failed)
                : .delivered(toolID: toolID)
        case .messageComplete(_, _, let status, let error, _):
            guard case .generating(let toolID) = current else { return nil }
            let failed = status == "error" || error != nil
            return .stopped(toolID: toolID, reason: failed ? .failed : .cancelled)
        case .error:
            guard case .generating(let toolID) = current else { return nil }
            return .stopped(toolID: toolID, reason: .failed)
        default:
            return nil
        }
    }

    /// The activity transition caused by a VM-verified stop that has no wire
    /// frame of its own: the user's interrupt settled, or the transport
    /// dropped. Nil when nothing was in flight.
    public static func stopped(
        _ current: ImageGenerationActivity?,
        reason: ImageGenerationStop
    ) -> ImageGenerationActivity? {
        guard case .generating(let toolID) = current else { return nil }
        return .stopped(toolID: toolID, reason: reason)
    }

    // MARK: Result classification

    /// Whether a `tool.complete` result payload is an explicit failure
    /// (Desktop parity — card D: only `success == false` is a failure; a
    /// non-object or unparseable payload is NOT one). A failed generation
    /// stops the animation and can never cite an artifact.
    public static func resultIndicatesFailure(_ resultJSON: String?) -> Bool {
        guard let resultJSON, !resultJSON.isEmpty,
              let object = GeneratedImageRules.jsonObject(resultJSON) else { return false }
        if let success = object["success"] as? Bool { return success == false }
        return false
    }

    // MARK: Presentation

    public enum Motion: Equatable, Sendable {
        /// The indeterminate wing animation runs.
        case animated
        /// Reduce Motion: the same branding, held still.
        case still
    }

    /// Reduce Motion decision — pure so the rule is unit-tested rather than
    /// re-derived at each call site.
    public static func motion(reduceMotion: Bool) -> Motion {
        reduceMotion ? .still : .animated
    }

    private static func started(
        current: ImageGenerationActivity?,
        name: String?,
        toolID: String?
    ) -> ImageGenerationActivity? {
        guard name == toolName else { return nil }
        if let current, current.isTerminal {
            // Never resurrect a finished call from a replayed/re-delivered
            // frame: a restart must PROVE a different call by carrying a
            // different tool id (the gateway mints one per call).
            guard let newID = toolID, let oldID = current.toolID, newID != oldID else {
                return nil
            }
        }
        return .generating(toolID: toolID)
    }
}

/// Visible copy + accessibility semantics for the generation animation.
///
/// Deliberately carries NO percentage, countdown, or estimated time: the
/// gateway reports no completion fraction for a generation, so none is
/// invented (card E: indeterminate by construction). Pinned by
/// `ImageGenerationActivityTests`.
public enum ImageGenerationCopy {
    /// The caption beside the wing mark. The ellipsis is the only time
    /// signal — there is no fabricated position or ETA.
    public static let caption = "Generating image…"
    /// The honest secondary line: states the indeterminacy instead of
    /// implying one.
    public static let detail = "This can take a while — no estimate is available."
    /// VoiceOver label for the animated element.
    public static let accessibilityLabel = "Generating image"
    /// VoiceOver value for the animated element (state, never quantity).
    public static let accessibilityValue = "In progress"
}
