import Foundation

/// Delivery state of one Watch-composed message. Only an explicit gateway
/// acknowledgement (relayed by the phone) reaches `.acknowledged`.
public enum WatchMessageState: Codable, Sendable, Hashable {
    /// Composed and explicitly sent, waiting for the phone to be reachable.
    /// Nothing has been transmitted to the phone yet.
    case queued
    /// Transmitted to the phone; no outcome yet.
    case sentToPhone
    case acknowledged
    /// Definitively not delivered. Safe to send again.
    case failed(reason: String)
    /// Transmitted but the outcome is unknown (timeout, disconnect, gateway
    /// uncertainty). Never auto-resent; the user decides.
    case uncertain(reason: String)
}

public struct WatchOutboxMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String { request.clientMessageID }
    public let request: WatchMessageRequest
    public var state: WatchMessageState
    public var updatedAt: Date
    /// Human labels frozen at compose time so a later context switch cannot
    /// make a pending message appear to target something else.
    public let targetLabel: String

    public init(request: WatchMessageRequest, state: WatchMessageState, updatedAt: Date, targetLabel: String) {
        self.request = request
        self.state = state
        self.updatedAt = updatedAt
        self.targetLabel = targetLabel
    }
}

public struct WatchMessageOutbox: Codable, Sendable, Equatable {
    public private(set) var messages: [WatchOutboxMessage] = []
    public static let capacity = 20

    public init() {}

    /// Enqueue an explicitly-sent message. Empty or over-long text is refused.
    @discardableResult
    public mutating func enqueue(_ request: WatchMessageRequest, targetLabel: String, now: Date) -> Bool {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, request.text.count <= WatchMessageRequest.maxTextLength else { return false }
        guard !messages.contains(where: { $0.id == request.clientMessageID }) else { return false }
        messages.append(WatchOutboxMessage(request: request, state: .queued, updatedAt: now, targetLabel: targetLabel))
        if messages.count > Self.capacity {
            // Drop only settled entries; unsettled ones are never silently lost.
            if let index = messages.firstIndex(where: { $0.state == .acknowledged }) {
                messages.remove(at: index)
            }
        }
        return true
    }

    /// Messages that may be transmitted automatically on reconnect: only those
    /// never transmitted before. Uncertain and failed ones are never included.
    public var autoTransmittable: [WatchOutboxMessage] {
        messages.filter { $0.state == .queued }
    }

    public mutating func markSent(_ id: String, now: Date) {
        update(id, now: now) { if $0.state == .queued { $0.state = .sentToPhone } }
    }

    public mutating func apply(_ reply: WatchMessageReply, now: Date) {
        update(reply.clientMessageID, now: now) { message in
            switch reply.outcome {
            case .acknowledged, .alreadyAcknowledged: message.state = .acknowledged
            case .rejected(let reason), .failed(let reason): message.state = .failed(reason: reason)
            case .uncertain(let reason): message.state = .uncertain(reason: reason)
            }
        }
    }

    /// Link loss / timeout after transmission: outcome unknown.
    public mutating func markUncertain(_ id: String, reason: String, now: Date) {
        update(id, now: now) {
            if $0.state == .sentToPhone { $0.state = .uncertain(reason: reason) }
        }
    }

    /// After a relaunch no in-flight request survives, so anything still
    /// `sentToPhone` is of unknown outcome.
    public mutating func recoverAfterRelaunch(now: Date) {
        for index in messages.indices where messages[index].state == .sentToPhone {
            messages[index].state = .uncertain(reason: "The Watch app restarted before a reply arrived.")
            messages[index].updatedAt = now
        }
    }

    /// Explicit user action ("Send again") for a failed/uncertain message. It
    /// keeps the same clientMessageID so the phone can dedupe, and goes back to
    /// `.queued` for one more transmission.
    @discardableResult
    public mutating func userRetry(_ id: String, now: Date) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        switch messages[index].state {
        case .failed, .uncertain:
            messages[index].state = .queued
            messages[index].updatedAt = now
            return true
        case .queued, .sentToPhone, .acknowledged:
            return false
        }
    }

    public mutating func remove(_ id: String) {
        messages.removeAll { $0.id == id }
    }

    private mutating func update(_ id: String, now: Date, _ change: (inout WatchOutboxMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
        messages[index].updatedAt = now
    }
}

/// Phone-side dedupe for messages by client ID.
public struct WatchMessageLedger: Codable, Sendable, Equatable {
    public enum Entry: Codable, Sendable, Equatable {
        case inFlight
        case finished(WatchMessageOutcome)
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    public static let capacity = 200

    public init() {}

    public enum Admission: Equatable, Sendable {
        case admit
        /// Already in flight: reply "uncertain/in progress", do not resend.
        case inFlight
        /// Already finished; return the prior outcome.
        case finished(WatchMessageOutcome)
    }

    public mutating func admit(_ clientMessageID: String) -> Admission {
        switch entries[clientMessageID] {
        case .inFlight: return .inFlight
        case .finished(let outcome):
            switch outcome {
            case .acknowledged, .alreadyAcknowledged: return .finished(.alreadyAcknowledged)
            // An uncertain send must not be repeated to the gateway.
            case .uncertain: return .finished(outcome)
            // A definite failure/rejection may be retried under the same ID.
            case .failed, .rejected:
                entries[clientMessageID] = .inFlight
                return .admit
            }
        case nil:
            entries[clientMessageID] = .inFlight
            order.append(clientMessageID)
            if order.count > Self.capacity { entries[order.removeFirst()] = nil }
            return .admit
        }
    }

    public mutating func finish(_ clientMessageID: String, outcome: WatchMessageOutcome) {
        entries[clientMessageID] = .finished(outcome)
    }
}
