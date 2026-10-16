import Foundation

/// Delivery state of one Watch-composed message. Only an explicit gateway
/// acknowledgement (relayed by the phone) reaches `.acknowledged`, and that
/// means the gateway ACCEPTED the prompt — not that the assistant replied.
public enum WatchMessageState: Codable, Sendable, Hashable {
    /// Composed and explicitly sent, waiting for the phone to be reachable.
    /// Nothing has been transmitted to the phone yet.
    case queued
    /// Transmitted to the phone; no outcome yet.
    case sentToPhone
    case acknowledged
    /// Definitively not submitted to the gateway (rejected or failed before
    /// acceptance). The only state that offers a resend.
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
    /// Safe stage diagnostic from the phone (never content or credentials).
    public var diagnostic: String?
    /// Human labels frozen at compose time so a later context switch cannot
    /// make a pending message appear to target something else.
    public let targetLabel: String

    public init(request: WatchMessageRequest, state: WatchMessageState, updatedAt: Date, targetLabel: String, diagnostic: String? = nil) {
        self.diagnostic = diagnostic
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
            message.diagnostic = reply.diagnostic?.text
            switch reply.outcome {
            case .acknowledged, .alreadyAcknowledged: message.state = .acknowledged
            case .rejected(let reason), .failed(let reason): message.state = .failed(reason: reason)
            case .uncertain(let reason): message.state = .uncertain(reason: reason)
            }
        }
    }

    /// The transport verified the link was down BEFORE sending, so nothing
    /// left the Watch: the message is simply still unsent.
    public mutating func requeueUnsent(_ id: String, now: Date) {
        update(id, now: now) { if $0.state == .sentToPhone { $0.state = .queued } }
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

    /// Explicit user action ("Send again"), offered ONLY for a message known
    /// not to have been submitted. An uncertain message may already have
    /// reached the gateway, so it is never resent from the Watch: the user
    /// checks the chat on iPhone or discards it. Keeps the same
    /// clientMessageID so the phone can dedupe.
    @discardableResult
    public mutating func userRetry(_ id: String, now: Date) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        guard case .failed = messages[index].state else { return false }
        messages[index].state = .queued
        messages[index].updatedAt = now
        return true
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

/// Phone-side admission and idempotency ledger, bound to message ID,
/// destination and payload (via `WatchMessageRequest.fingerprint`). It is
/// persisted BEFORE dispatch, so a phone restart or WatchConnectivity replay
/// can never cause a second submit. It stores only IDs, fingerprints and
/// outcomes — never message text.
public struct WatchMessageLedger: Codable, Sendable, Equatable {
    public enum State: Codable, Sendable, Equatable {
        /// Admitted and (about to be) dispatched; outcome not yet recorded.
        case admitted
        case finished(WatchMessageOutcome)
    }

    public struct Record: Codable, Sendable, Equatable {
        public var fingerprint: String
        public var state: State
    }

    private var records: [String: Record] = [:]
    private var order: [String] = []
    public static let capacity = 200

    public init() {}

    public enum Admission: Equatable, Sendable {
        case admit
        /// Already being sent in this phone process: do not dispatch again.
        case inFlight
        /// Already finished; return the prior outcome without dispatching.
        case finished(WatchMessageOutcome)
        /// Same ID, different destination or payload. Never dispatched.
        case conflict
    }

    public mutating func admit(_ request: WatchMessageRequest) -> Admission {
        let id = request.clientMessageID
        let fingerprint = request.fingerprint
        if let record = records[id] {
            guard record.fingerprint == fingerprint else { return .conflict }
            switch record.state {
            case .admitted: return .inFlight
            case .finished(let outcome):
                switch outcome {
                case .acknowledged, .alreadyAcknowledged: return .finished(.alreadyAcknowledged)
                // An uncertain send must not be repeated to the gateway.
                case .uncertain: return .finished(outcome)
                // Definitely not submitted: the same message may be retried.
                case .failed, .rejected:
                    records[id]?.state = .admitted
                    return .admit
                }
            }
        }
        records[id] = Record(fingerprint: fingerprint, state: .admitted)
        order.append(id)
        if order.count > Self.capacity { records[order.removeFirst()] = nil }
        return .admit
    }

    /// Takes back an admission that was never dispatched (e.g. it could not be
    /// persisted).
    public mutating func revokeAdmission(_ request: WatchMessageRequest) {
        let id = request.clientMessageID
        guard records[id]?.state == .admitted else { return }
        records[id] = nil
        order.removeAll { $0 == id }
    }

    public mutating func finish(_ clientMessageID: String, outcome: WatchMessageOutcome) {
        records[clientMessageID]?.state = .finished(outcome)
    }

    /// After a phone restart nothing is in flight: an entry still `admitted`
    /// was written before dispatch, so its outcome is unknown. Never retried.
    public mutating func recoverAfterRestart() {
        for (id, record) in records where record.state == .admitted {
            records[id]?.state = .finished(.uncertain(
                reason: "Hermes Fleet on iPhone restarted while this was being sent."))
        }
    }

    public func state(of clientMessageID: String) -> State? { records[clientMessageID]?.state }
}

public protocol WatchMessageLedgerStoring: AnyObject {
    /// A missing store is an empty ledger; an unreadable one THROWS so sends
    /// fail closed rather than forgetting what was already dispatched.
    func load() throws -> WatchMessageLedger
    func save(_ ledger: WatchMessageLedger) throws
}

public final class InMemoryWatchMessageLedgerStore: WatchMessageLedgerStoring {
    public private(set) var saved: WatchMessageLedger?
    public var failSaves = false
    public init() {}
    public var failLoads = false
    public func load() throws -> WatchMessageLedger {
        if failLoads { throw CocoaError(.fileReadCorruptFile) }
        return saved ?? WatchMessageLedger()
    }
    public func save(_ ledger: WatchMessageLedger) throws {
        if failSaves { throw CocoaError(.fileWriteUnknown) }
        saved = ledger
    }
}

/// File-backed ledger. Written atomically with file protection that still
/// allows a background WatchConnectivity wake after first unlock.
public final class FileWatchMessageLedgerStore: WatchMessageLedgerStoring {
    private let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetWatchDev/phone-message-ledger.json")
    }

    public func load() throws -> WatchMessageLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return WatchMessageLedger() }
        return try JSONDecoder().decode(WatchMessageLedger.self, from: Data(contentsOf: url))
    }

    public func save(_ ledger: WatchMessageLedger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
