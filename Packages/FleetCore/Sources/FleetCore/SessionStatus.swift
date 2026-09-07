import Foundation

/// The read-only `session.status` result.
///
/// Wire shape (verified in `tui_gateway/methods_session.py:2702-2775`): the
/// gateway returns a human-oriented text block in `{"output": "..."}` (Session
/// ID / Path / Model / Created / Last Activity / Tokens / Agent Running). The
/// client preserves the authoritative raw text and additionally exposes a
/// best-effort parse of the stable, documented lines so the UI can render
/// status without scraping; every parsed field falls back to `nil` rather
/// than failing the call (spec §5.5 tolerant decoding).
public struct SessionStatus: Hashable, Sendable {
    /// The gateway's authoritative human-readable status text (verbatim).
    public let rawOutput: String

    /// Best-effort parse of the `Session ID:` line.
    public let sessionID: String?
    /// Best-effort parse of the `Model:` line (`model (provider)`).
    public let model: String?
    /// Best-effort parse of the `Provider:` portion of the `Model:` line.
    public let provider: String?
    /// Best-effort parse of the `Title:` line (absent when untitled).
    public let title: String?
    /// Best-effort parse of the `Agent Running: Yes/No` line.
    public let agentRunning: Bool?

    public init(
        rawOutput: String,
        sessionID: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        title: String? = nil,
        agentRunning: Bool? = nil
    ) {
        self.rawOutput = rawOutput
        self.sessionID = sessionID
        self.model = model
        self.provider = provider
        self.title = title
        self.agentRunning = agentRunning
    }

    /// Parse the gateway's status text block. Every field is best-effort: a
    /// changed or absent line yields `nil` for that field, never a failure.
    public static func parse(output: String) -> SessionStatus {
        var sessionID: String?
        var model: String?
        var provider: String?
        var title: String?
        var agentRunning: Bool?

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Session ID:") {
                sessionID = value(after: "Session ID:", in: trimmed)
            } else if trimmed.hasPrefix("Model:") {
                let modelLine = value(after: "Model:", in: trimmed) ?? ""
                // "Model: deepseek-v4-flash (nous)" → model + provider.
                let parts = modelLine.split(separator: "(", maxSplits: 1)
                if parts.count == 2 {
                    model = parts[0].trimmingCharacters(in: .whitespaces)
                    provider = parts[1]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: ")", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    model = modelLine.isEmpty ? nil : modelLine
                }
            } else if trimmed.hasPrefix("Title:") {
                let t = value(after: "Title:", in: trimmed) ?? ""
                title = t.isEmpty ? nil : t
            } else if trimmed.hasPrefix("Agent Running:") {
                let v = (value(after: "Agent Running:", in: trimmed) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if v == "yes" || v == "true" {
                    agentRunning = true
                } else if v == "no" || v == "false" {
                    agentRunning = false
                }
            }
        }

        return SessionStatus(
            rawOutput: output,
            sessionID: sessionID,
            model: model,
            provider: provider,
            title: title,
            agentRunning: agentRunning
        )
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix) else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
