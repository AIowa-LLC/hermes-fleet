import Foundation

/// The result of `prompt.submit`.
///
/// Wire shape (verified in `tui_gateway/methods_prompt.py:918`): the handler
/// returns `{"status": "streaming"}` immediately and streams the turn's
/// `message.*` / `tool.*` / `status.*` / `thinking.*` / `reasoning.*` events
/// over the gateway event stream. `isStreaming` is the contract the composer
/// waits on before showing the in-progress state.
public struct PromptSubmission: Hashable, Sendable {
    /// The gateway-reported submission status (`"streaming"`).
    public let status: String

    public init(status: String) {
        self.status = status
    }

    /// Whether the turn is streaming (the normal accepted state).
    public var isStreaming: Bool { status == "streaming" }
}
