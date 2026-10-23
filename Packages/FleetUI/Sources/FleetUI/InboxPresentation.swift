import Foundation
import FleetCore
import FleetSecurity

/// Pure presentation rules for the approvals inbox: section order, row copy,
/// availability, plain-language errors, audit wording, and the deep-link
/// grammar. No SwiftUI and no store access, so every rule is unit-testable.
///
/// Secret rule: nothing here reads or renders a typed answer. Secret and sudo
/// rows show the variable NAME or the command only.
public enum FleetInboxPresentation {

    // MARK: Sections

    public struct Sections: Equatable, Sendable {
        /// Waiting for a decision, newest first.
        public var pending: [InboxItem]
        /// Resolved items, most recently resolved first.
        public var history: [InboxItem]
    }

    public static func sections(_ items: [InboxItem]) -> Sections {
        var pending: [InboxItem] = []
        var history: [InboxItem] = []
        for item in items {
            if item.status == .pending {
                pending.append(item)
            } else {
                history.append(item)
            }
        }
        pending.sort { ($0.createdAt, $0.id.rawValue) > ($1.createdAt, $1.id.rawValue) }
        history.sort { ($0.updatedAt, $0.id.rawValue) > ($1.updatedAt, $1.id.rawValue) }
        return Sections(pending: pending, history: history)
    }

    public static func pendingCount(_ items: [InboxItem]) -> Int {
        items.reduce(0) { $0 + ($1.status == .pending ? 1 : 0) }
    }

    // MARK: Row copy

    public static func symbol(for kind: InboxItemKind) -> String {
        switch kind {
        case .approval: "exclamationmark.shield"
        case .question: "questionmark.bubble"
        case .sudo: "lock.shield"
        case .secret: "key"
        }
    }

    public static func kindTitle(_ kind: InboxItemKind) -> String {
        switch kind {
        case .approval: "Command approval"
        case .question: "Question"
        case .sudo: "Sudo password"
        case .secret: "Secret"
        }
    }

    /// Whether the summary is a shell command (rendered monospaced).
    public static func summaryIsCommand(_ item: InboxItem) -> Bool {
        (item.kind == .approval || item.kind == .sudo) && item.context.command != nil
    }

    /// The one-line action summary for a row. Never a secret value.
    public static func actionSummary(_ item: InboxItem) -> String {
        switch item.kind {
        case .approval:
            return firstLine(item.context.command) ?? "Command approval"
        case .sudo:
            return firstLine(item.context.command) ?? "Sudo password requested"
        case .question:
            return firstLine(item.context.detail) ?? "Question from agent"
        case .secret:
            if let name = item.context.envVarName.flatMap(nonBlank) {
                return "Secret requested: \(name)"
            }
            return "Secret requested"
        }
    }

    /// `<profile or bot> · <gateway>`.
    public static func agentLine(_ item: InboxItem) -> String {
        let who = item.agent.profileName.flatMap(nonBlank) ?? "Bot"
        return "\(who) · \(item.agent.gatewayLabel)"
    }

    /// The session title, or a short id when the title is unknown.
    public static func sessionLine(_ item: InboxItem) -> String {
        ApprovalOrigin.sessionLabel(title: item.agent.sessionTitle, id: item.agent.sessionID) ?? "Session"
    }

    public enum ChipTone: Equatable, Sendable {
        case attention
        case success
        case destructive
        case muted
    }

    public struct Chip: Equatable, Sendable {
        public let text: String
        public let tone: ChipTone
    }

    public static func chip(for item: InboxItem) -> Chip {
        switch item.status {
        case .pending:
            return Chip(text: "Waiting for you", tone: .attention)
        case .approved:
            return Chip(text: "Approved", tone: .success)
        case .denied:
            return Chip(text: "Denied", tone: .muted)
        case .answered:
            return Chip(text: "Answered", tone: .success)
        case .expired:
            return Chip(text: dimmedReason(item) ?? "Expired", tone: .muted)
        case .cancelled:
            return Chip(text: "Withdrawn", tone: .muted)
        case .failed:
            return Chip(text: "Couldn't complete", tone: .destructive)
        }
    }

    /// Explains a dimmed (expired or cancelled) row. Nil for other statuses.
    /// An expiry that carries a failure note means the gateway said the request
    /// was answered somewhere else; a bare expiry means it stopped listing it.
    public static func dimmedReason(_ item: InboxItem) -> String? {
        switch item.status {
        case .expired:
            return item.failureMessage == nil ? "Expired" : "Answered elsewhere"
        case .cancelled:
            return "Withdrawn by agent"
        case .pending, .approved, .denied, .answered, .failed:
            return nil
        }
    }

    public static func isDimmed(_ item: InboxItem) -> Bool {
        item.status == .expired || item.status == .cancelled
    }

    /// The display-safe failure note, when one is recorded.
    public static func failureNote(_ item: InboxItem) -> String? {
        item.failureMessage.flatMap(nonBlank)
    }

    // MARK: Reachability and availability

    /// Gateway ids whose connection is live, from the app's connection map.
    public static func connectedGatewayIDs(
        gatewayIDs: [GatewayID],
        state: (GatewayID) -> GatewayConnectionState
    ) -> Set<GatewayID> {
        Set(gatewayIDs.filter { state($0) == .connected })
    }

    /// True when no gateway is connected: pending items may be stale and no
    /// decision can reach a gateway.
    public static func isOffline(connected: Set<GatewayID>) -> Bool {
        connected.isEmpty
    }

    public static let offlineTitle = "Offline"
    public static let offlineBody = "Pending items may be out of date, and decisions can't be sent until a gateway reconnects."

    public struct Availability: Equatable, Sendable {
        /// Approve scopes are offered and enabled.
        public let canApprove: Bool
        /// Deny is offered and enabled.
        public let canDeny: Bool
        /// A typed answer or a choice can be sent.
        public let canAnswer: Bool
        /// The item can only be answered in its conversation (batch clarify).
        public let answersInSessionOnly: Bool

        public static let none = Availability(canApprove: false, canDeny: false, canAnswer: false, answersInSessionOnly: false)
    }

    public static func availability(for item: InboxItem, reachable: Bool) -> Availability {
        guard item.status == .pending else { return .none }
        if item.kind == .question, item.context.isBatchQuestion {
            return Availability(canApprove: false, canDeny: false, canAnswer: false, answersInSessionOnly: true)
        }
        guard reachable else { return .none }
        switch item.kind {
        case .approval:
            return Availability(canApprove: true, canDeny: true, canAnswer: false, answersInSessionOnly: false)
        case .question, .sudo, .secret:
            return Availability(canApprove: false, canDeny: false, canAnswer: true, answersInSessionOnly: false)
        }
    }

    /// The approve scopes to offer: once always, then the broader scopes only
    /// when the gateway offered them (mirrors the conversation banner).
    public static func approveChoices(for item: InboxItem) -> [ApprovalChoice] {
        let offered = Set(item.context.choices)
        var choices: [ApprovalChoice] = [.once]
        if offered.contains("session") { choices.append(.session) }
        if offered.contains("always") { choices.append(.always) }
        return choices
    }

    public static func approveTitle(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "Approve once"
        case .session: "Approve for this session"
        case .always: "Approve always"
        case .deny: "Deny"
        }
    }

    /// Choices offered for a single clarify question (empty for a batch, which
    /// is answered in its conversation).
    public static func answerChoices(_ item: InboxItem) -> [String] {
        item.context.isBatchQuestion ? [] : item.context.choices
    }

    /// Approve needs the full command reviewed when the preview elides it.
    public static func requiresReview(_ item: InboxItem) -> Bool {
        guard item.kind == .approval, let command = item.context.command else { return false }
        return ApprovalCommandPreview(command: command).requiresReview
    }

    // MARK: Errors

    /// Plain-language text for a failed decision. Never echoes a command or an
    /// answer.
    public static func message(for error: Error) -> String {
        guard let inboxError = error as? InboxError else {
            return "Something went wrong. Nothing was confirmed. Try again."
        }
        switch inboxError {
        case .notFound:
            return "This request is no longer in the inbox."
        case .notPending:
            return "This request was already answered."
        case .reviewRequired:
            return "Review the full command before approving."
        case .presenceNotVerified(let result):
            switch result {
            case .cancelled: return "Approval was cancelled. Nothing was sent."
            case .passcodeNotSet: return "Set a device passcode to approve. Nothing was sent."
            case .failed, .verified: return "Couldn't confirm it's you. Nothing was sent."
            }
        case .unsupportedKind:
            return "Answer this one in its conversation."
        case .gatewayUnavailable:
            return "This gateway is offline. Nothing was sent. Reconnect to answer."
        case .gatewayRejected(let text):
            return nonBlank(text) ?? "The gateway didn't accept this. Try again."
        }
    }

    /// A live server request (approval, clarify, sudo, secret) is answered only
    /// while its conversation is open in the app. When the store refuses a
    /// decision for that reason, the user is pointed at the session rather than
    /// shown a generic failure.
    public static let openSessionToAnswerMessage = "Open the session to answer this request. Nothing was sent."

    /// True when a failed decision should be explained as "open the session".
    public static func needsOpenSession(_ error: Error, item: InboxItem) -> Bool {
        guard let inboxError = error as? InboxError, inboxError == .gatewayUnavailable else { return false }
        return item.serverRequestID != nil
    }

    // MARK: Audit

    public static func actionTitle(_ action: InboxDecisionAction) -> String {
        switch action {
        case .approveOnce: "Approved once"
        case .approveSession: "Approved for this session"
        case .approveAlways: "Approved always"
        case .deny: "Denied"
        case .answer: "Answered"
        case .skip: "Skipped"
        }
    }

    /// "You on this device" for this device's decisions; otherwise the owner's
    /// name or the recorded device label.
    public static func deciderTitle(_ decider: InboxDecider) -> String {
        if decider.deviceLabel == InboxDecider.thisDevice(ownerName: nil).deviceLabel {
            return "You on this device"
        }
        return decider.ownerName.flatMap(nonBlank) ?? decider.deviceLabel
    }

    public static func outcomeTitle(_ outcome: InboxDecisionOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "Accepted by gateway"
        case .failed(let message):
            return nonBlank(message).map { "Not accepted: \($0)" } ?? "Not accepted"
        }
    }

    public static func outcomeFailed(_ outcome: InboxDecisionOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    /// Audit records for one item, in trail order (newest first).
    public static func audit(_ records: [InboxDecisionRecord], for itemID: InboxItemID) -> [InboxDecisionRecord] {
        records.filter { $0.itemID == itemID }
    }

    // MARK: Session navigation

    /// The route that owns the item's session, when this device has loaded it.
    /// Nil keeps "Open session" honest: no route is guessed from a name.
    public static func route(for item: InboxItem, in sessionsByRoute: [Route: [SessionSummary]]) -> Route? {
        sessionsByRoute.first { route, sessions in
            route.gatewayID == item.agent.gatewayID && sessions.contains { $0.id == item.agent.sessionID }
        }?.key
    }

    // MARK: Helpers

    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return nonBlank(line)
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `<scheme>://inbox` opens the Inbox; `<scheme>://inbox?item=<id>` opens it
/// focused on one item. The scheme is the app's conversation scheme (per build
/// variant), so no new URL registration is needed.
public enum FleetInboxDeepLink {
    public static let host = "inbox"
    static let itemQueryName = "item"
    /// Longest item id accepted from a URL (guards against oversized input).
    static let maxItemIDLength = 512

    public struct Target: Equatable, Sendable {
        public let itemID: InboxItemID?
    }

    public static func url(focus itemID: InboxItemID? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = FleetAppIdentity.conversationURLScheme
        components.host = host
        if let itemID {
            components.queryItems = [URLQueryItem(name: itemQueryName, value: itemID.rawValue)]
        }
        return components.url
    }

    /// Nil when the URL is not an inbox link. A malformed item id opens the
    /// Inbox without focus instead of failing.
    public static func target(from url: URL) -> Target? {
        guard url.scheme == FleetAppIdentity.conversationURLScheme, url.host == host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let raw = items.first { $0.name == itemQueryName }?.value
        guard let raw, isValidItemID(raw) else { return Target(itemID: nil) }
        return Target(itemID: InboxItemID(rawValue: raw))
    }

    static func isValidItemID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= maxItemIDLength else { return false }
        // The composite is `gateway#session#request`: three non-empty parts.
        let parts = raw.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return raw.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0 != " " }
    }
}
