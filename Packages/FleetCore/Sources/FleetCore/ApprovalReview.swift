import Foundation

/// P0.2a — approval integrity: where an approval came from, how much of the
/// command the collapsed card may show, and whether the user has reviewed the
/// whole command before Approve is allowed.
///
/// These are pure value types so the rules are unit-testable without UI and
/// shared by every approve surface (conversation banner, Home Live Ops).

// MARK: - Origin

/// Who is asking. Built by the client from its own conversation context —
/// NEVER from the wire payload — so a hostile command or `detail` string
/// cannot forge it. Every field is always present: an unknown value renders as
/// "unknown" instead of being omitted, so a missing origin is visible.
public struct ApprovalOrigin: Equatable, Hashable, Sendable {
    /// Placeholder shown for any field the client does not know.
    public static let unknownValue = "unknown"
    /// Labels (gateway, bot, session) are capped so a long value cannot push
    /// the rest of the header out of view.
    public static let maxLabelLength = 80

    public let gatewayLabel: String
    public let botLabel: String
    public let cwd: String
    public let sessionLabel: String

    public init(gateway: String?, bot: String?, cwd: String?, session: String?) {
        self.gatewayLabel = Self.normalize(gateway, limit: Self.maxLabelLength)
        self.botLabel = Self.normalize(bot, limit: Self.maxLabelLength)
        self.cwd = Self.normalize(cwd, limit: nil)
        self.sessionLabel = Self.normalize(session, limit: Self.maxLabelLength)
    }

    /// Every field unknown.
    public static let unknown = ApprovalOrigin(gateway: nil, bot: nil, cwd: nil, session: nil)

    /// Session shown as its title when known, else a short id.
    public static func sessionLabel(title: String?, id: String?) -> String? {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return String(id.prefix(8))
        }
        return nil
    }

    /// Spoken as one phrase so VoiceOver reads the origin before the command.
    public var accessibilityDescription: String {
        "From gateway \(gatewayLabel), bot \(botLabel), working folder \(cwd), session \(sessionLabel)."
    }

    /// Collapse whitespace/control characters (a multi-line label could
    /// imitate extra UI rows), trim, cap, and substitute "unknown" when empty.
    private static func normalize(_ value: String?, limit: Int?) -> String {
        guard let value else { return unknownValue }
        let cleaned = value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return unknownValue }
        if let limit, cleaned.count > limit {
            return String(cleaned.prefix(limit - 1)) + "…"
        }
        return cleaned
    }
}

// MARK: - Collapsed preview

/// The collapsed card's view of a command: a bounded head of the text plus an
/// explicit count of what is NOT shown. The elision is computed here, never
/// left to SwiftUI's silent ellipsis, and it is always at the END of the
/// text (no middle truncation that could hide `| sh` between two visible
/// halves).
public struct ApprovalCommandPreview: Equatable, Sendable {
    /// Maximum logical lines the collapsed card shows.
    public static let maxLines = 4
    /// Maximum characters the collapsed card shows.
    public static let maxCharacters = 240

    /// Text safe to render inline (a prefix of the command).
    public let visibleText: String
    public let totalLines: Int
    public let totalCharacters: Int
    /// Lines that do not appear at all in `visibleText`.
    public let hiddenLines: Int
    /// Characters missing from `visibleText`.
    public let hiddenCharacters: Int

    public init(command: String) {
        let lines = Self.lines(of: command)
        totalLines = lines.count
        totalCharacters = command.count

        var shown: [Substring] = []
        var partial = false
        var budget = Self.maxCharacters
        for line in lines.prefix(Self.maxLines) {
            if line.count <= budget {
                shown.append(line)
                budget -= line.count + 1  // +1 for the newline that rejoins it
            } else {
                if budget > 0 { shown.append(line.prefix(budget)) }
                partial = true
                budget = 0
                break
            }
            if budget <= 0 { break }
        }
        visibleText = shown.joined(separator: "\n")
        // A partially shown last line still counts as shown. A trailing
        // newline on otherwise fully shown text is not an elision.
        let elided = partial || lines.count > shown.count
        hiddenCharacters = elided ? max(1, command.count - visibleText.count) : 0
        hiddenLines = max(0, lines.count - shown.count)
    }

    /// True when any part of the command is not shown inline.
    public var isElided: Bool { hiddenCharacters > 0 }

    /// Above the inline limit the user must review the full command before
    /// Approve is enabled.
    public var requiresReview: Bool { isElided }

    /// Visible, never-silent marker shown under the truncated text.
    public var elisionMarker: String? {
        guard isElided else { return nil }
        var parts: [String] = []
        if hiddenLines > 0 {
            parts.append("\(hiddenLines) more \(hiddenLines == 1 ? "line" : "lines")")
        }
        parts.append("\(hiddenCharacters) more \(hiddenCharacters == 1 ? "character" : "characters")")
        return "… " + parts.joined(separator: " · ") + " not shown"
    }

    /// Logical line count for the review sheet's "N lines" readout.
    public static func lines(of text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A single trailing newline does not add a visible line.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

// MARK: - Review tracking

/// Records which approvals the user has reviewed in full. Keyed by request id
/// AND command text: if the same request id ever re-arrives carrying different
/// command text, the earlier review does not carry over.
public struct ApprovalReviewTracker: Equatable, Sendable {
    private var reviewed: Set<String> = []

    public init() {}

    private static func key(_ request: ApprovalRequest) -> String {
        "\(request.requestID)\u{0}\(request.command)"
    }

    /// Whether Approve must wait for a review of this request.
    public func requiresReview(_ request: ApprovalRequest) -> Bool {
        ApprovalCommandPreview(command: request.command).requiresReview
    }

    public func isReviewed(_ request: ApprovalRequest) -> Bool {
        reviewed.contains(Self.key(request))
    }

    /// Approve is allowed when the command is short or has been reviewed.
    /// Deny is never gated by this.
    public func canApprove(_ request: ApprovalRequest) -> Bool {
        !requiresReview(request) || isReviewed(request)
    }

    public mutating func markReviewed(_ request: ApprovalRequest) {
        reviewed.insert(Self.key(request))
    }

    public mutating func forget(requestID: String) {
        reviewed = reviewed.filter { !$0.hasPrefix(requestID + "\u{0}") }
    }

    /// Drop every record except those for the given live request ids.
    public mutating func retain(requestIDs: Set<String>) {
        reviewed = reviewed.filter { entry in
            guard let id = entry.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).first else {
                return false
            }
            return requestIDs.contains(String(id))
        }
    }
}
