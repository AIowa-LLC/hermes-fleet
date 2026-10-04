import Foundation

/// R3 (#89) tap-routing seam — pure FleetCore domain, no UIKit, no crypto,
/// no networking. It consumes the already-OPENED v1 sealed payload (schema
/// from the push sender, `push_payload.py` `build_payload`/`build_withdrawal`)
/// and answers four questions deterministically:
///
/// 1. What may be shown on a notification (`NotificationPresentation`) given
///    App Lock, device lock state and decryption success?
/// 2. Is this delivery new, a replay or an expired leftover
///    (`NotificationReplayLedger`)?
/// 3. Which gateway/session/request does a tap target
///    (`NotificationTapTarget`)?
/// 4. What truthful screen should a tap open given the current gateway and
///    request state (`NotificationTapResolver`)?
///
/// Invariants:
/// - A notification is NEVER authoritative state. Resolution only chooses a
///   navigation destination; the foreground `approval.pending` read decides
///   whether a request is still actionable.
/// - Tapping is navigation, not approval. No type here carries an
///   `ApprovalChoice`, and `response_token` is deliberately not decoded, so
///   it cannot be retained, logged or forwarded from this layer.
/// - Failures degrade to generic content and a safe destination, never to a
///   guess.
public enum NotificationKind: String, Sendable, Equatable, Codable {
    case approval
    case clarify
    case done
    case cron
    /// Instruction to remove a delivered notification (`collapse_id`).
    case withdraw
}

/// Why an opened payload was rejected. Callers treat every case identically
/// (generic alert); the cases exist for tests and redacted diagnostics.
public enum NotificationPayloadError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case unknownKind
    case invalidTimes
    case invalidIdentity
}

/// The v1 payload after HPKE open. Only routing and display fields are
/// decoded; `response_token` and `command_digest` are intentionally ignored.
public struct OpenedNotificationPayload: Sendable, Equatable {
    public static let supportedVersion = 1
    static let maxFieldLength = 128

    public let kind: NotificationKind
    public let gatewayLabel: String
    public let bot: String
    public let sessionID: String
    public let requestID: String?
    /// Session-level reference (stable per session); never a request identity.
    public let requestRef: String
    public let isHighRisk: Bool
    public let createdAt: Date
    public let expiresAt: Date
    public let nonce: String
    public let redactedPreview: String?
    /// Only for `.withdraw`: identifier of the delivered notification.
    public let collapseID: String?

    private struct Wire: Decodable {
        let v: Int
        let kind: String
        let gateway_label: String?
        let bot: String?
        let session_id: String
        let request_id: String?
        let request_ref: String?
        let risk: String?
        let created_at: Double
        let expires_at: Double
        let nonce: String
        let redacted_preview: String?
        let collapse_id: String?
    }

    /// Strictly decode and validate an opened payload.
    public init(json: Data) throws {
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: json) } catch { throw NotificationPayloadError.malformed }
        guard wire.v == Self.supportedVersion else { throw NotificationPayloadError.unsupportedVersion }
        guard let kind = NotificationKind(rawValue: wire.kind) else { throw NotificationPayloadError.unknownKind }
        guard wire.created_at.isFinite, wire.expires_at.isFinite, wire.expires_at > wire.created_at else {
            throw NotificationPayloadError.invalidTimes
        }
        guard Self.isSafeToken(wire.session_id), Self.isSafeToken(wire.nonce),
              wire.request_id.map(Self.isSafeToken) ?? true,
              wire.collapse_id.map(Self.isSafeToken) ?? true
        else { throw NotificationPayloadError.invalidIdentity }
        if kind == .withdraw, wire.collapse_id == nil { throw NotificationPayloadError.invalidIdentity }
        self.kind = kind
        self.gatewayLabel = wire.gateway_label ?? ""
        self.bot = wire.bot ?? ""
        self.sessionID = wire.session_id
        self.requestID = wire.request_id
        self.requestRef = wire.request_ref ?? ""
        self.isHighRisk = wire.risk == "high"
        self.createdAt = Date(timeIntervalSince1970: wire.created_at)
        self.expiresAt = Date(timeIntervalSince1970: wire.expires_at)
        self.nonce = wire.nonce
        self.redactedPreview = wire.redacted_preview
        self.collapseID = wire.collapse_id
    }

    static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maxFieldLength
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Identity of the thing the user is being asked about. A reconnect or a
    /// re-push of the same request yields the same key with a fresh nonce.
    public var deliveryKey: String {
        "\(kind.rawValue)|\(sessionID)|\(requestID ?? requestRef)"
    }
}

// MARK: - Presentation (redaction)

/// What the Notification Service Extension may put on screen.
public struct NotificationPresentation: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Stable per-delivery-key identifier so a repeat replaces, not stacks.
    public let threadIdentifier: String?

    /// Environment facts the extension can read (App Group flags).
    public struct Context: Equatable, Sendable {
        public var appLockEnabled: Bool
        public var deviceLocked: Bool
        /// User's "hide previews" preference (defaults on with App Lock).
        public var hidePreviews: Bool

        public init(appLockEnabled: Bool, deviceLocked: Bool, hidePreviews: Bool) {
            self.appLockEnabled = appLockEnabled
            self.deviceLocked = deviceLocked
            self.hidePreviews = hidePreviews
        }
    }

    /// Generic copy: reveals nothing but the kind. Used on decryption
    /// failure, tamper, wrong key, expiry or any redaction condition.
    public static func generic(for kind: NotificationKind? = nil) -> NotificationPresentation {
        switch kind {
        case .approval: return .init(title: "Approval needed", body: "Open Fleet to review.", threadIdentifier: nil)
        case .clarify: return .init(title: "Question waiting", body: "Open Fleet to answer.", threadIdentifier: nil)
        case .done: return .init(title: "Task finished", body: "Open Fleet to see the result.", threadIdentifier: nil)
        case .cron: return .init(title: "Scheduled task update", body: "Open Fleet for details.", threadIdentifier: nil)
        case .withdraw, nil: return .init(title: "Fleet", body: "Open Fleet to see what's new.", threadIdentifier: nil)
        }
    }

    /// Decide the content for an opened payload. `nil` payload means opening
    /// failed (wrong device key, tampering, timeout): generic only.
    public static func content(
        for payload: OpenedNotificationPayload?,
        context: Context,
        now: Date
    ) -> NotificationPresentation {
        guard let payload, payload.kind != .withdraw, payload.expiresAt > now else { return .generic() }
        let base = generic(for: payload.kind)
        let redact = context.appLockEnabled || context.hidePreviews || context.deviceLocked
        guard !redact else { return base }
        var body = base.body
        if let preview = payload.redactedPreview, !preview.isEmpty, payload.kind == .approval {
            body = payload.isHighRisk ? "High risk: open Fleet to review the full command." : preview
        }
        let title = payload.gatewayLabel.isEmpty ? base.title : "\(base.title) · \(payload.gatewayLabel)"
        return .init(title: title, body: body, threadIdentifier: payload.deliveryKey)
    }
}

// MARK: - Replay / duplicate guard

/// Bounded, value-type ledger of deliveries already presented. Persisting it
/// (App Group, NSE + app) is a follow-up; this type is the policy.
public struct NotificationReplayLedger: Sendable, Equatable {
    public enum Decision: Equatable, Sendable {
        case present
        /// Same nonce seen before (relay retry / replay).
        case replayedNonce
        /// Same request already shown under a different nonce (reconnect
        /// re-push). Replaces in place, must not prompt twice.
        case duplicateRequest
        case expired
    }

    public let capacity: Int
    private var nonces: [String] = []
    private var keys: [String: Date] = [:]

    public init(capacity: Int = 256) {
        self.capacity = max(8, capacity)
    }

    public mutating func admit(_ payload: OpenedNotificationPayload, now: Date) -> Decision {
        guard payload.expiresAt > now else { return .expired }
        if nonces.contains(payload.nonce) { return .replayedNonce }
        remember(nonce: payload.nonce)
        // Drop settled keys first so a long-lived ledger cannot grow.
        keys = keys.filter { $0.value > now }
        if payload.kind == .withdraw { return .present }
        if keys[payload.deliveryKey] != nil { return .duplicateRequest }
        keys[payload.deliveryKey] = payload.expiresAt
        return .present
    }

    /// A withdrawal frees the key so a genuinely new later request with the
    /// same identity (not expected, but safe) is not suppressed forever.
    public mutating func settle(deliveryKey: String) {
        keys.removeValue(forKey: deliveryKey)
    }

    private mutating func remember(nonce: String) {
        nonces.append(nonce)
        if nonces.count > capacity { nonces.removeFirst(nonces.count - capacity) }
    }
}

// MARK: - Tap routing

/// Local, secret-free routing record attached to the delivered notification
/// after the payload is opened (the relay never sees it).
public struct NotificationTapTarget: Equatable, Sendable, Codable {
    public let gatewayID: GatewayID?
    public let gatewayLabel: String
    public let sessionID: String
    public let requestID: String?
    public let kind: NotificationKind
    public let expiresAt: Date

    public init(
        gatewayID: GatewayID?,
        gatewayLabel: String,
        sessionID: String,
        requestID: String?,
        kind: NotificationKind,
        expiresAt: Date
    ) {
        self.gatewayID = gatewayID
        self.gatewayLabel = gatewayLabel
        self.sessionID = sessionID
        self.requestID = requestID
        self.kind = kind
        self.expiresAt = expiresAt
    }

    /// Build a target. `registeredGatewayID` (from the local push
    /// registration that owns the key which opened the payload) wins; the
    /// sealed `gateway_label` is only a fallback and must match exactly one
    /// gateway, because a display name is not an identity.
    public init(
        payload: OpenedNotificationPayload,
        registeredGatewayID: GatewayID? = nil,
        gateways: [FleetGateway] = []
    ) {
        var resolved = registeredGatewayID
        if resolved == nil, !payload.gatewayLabel.isEmpty {
            let matches = gateways.filter { $0.displayName == payload.gatewayLabel }
            if matches.count == 1 { resolved = matches[0].id }
        }
        self.init(
            gatewayID: resolved,
            gatewayLabel: payload.gatewayLabel,
            sessionID: payload.sessionID,
            requestID: payload.requestID,
            kind: payload.kind,
            expiresAt: payload.expiresAt
        )
    }
}

/// Authoritative request state as last read from the gateway
/// (`approval.pending`), if any.
public enum NotificationRequestStatus: Equatable, Sendable {
    case pending
    /// The gateway answered and the request is not in its pending list.
    case notPending
    /// Not read yet (offline, still connecting, App Lock not yet cleared).
    case unverified
}

/// Where a tap navigates. Every case is navigation only.
public enum NotificationTapDestination: Equatable, Sendable {
    /// Open the request in its session; the in-app card still requires the
    /// existing full-command review, biometric and presence checks.
    case request(gatewayID: GatewayID, sessionID: String, requestID: String?)
    /// Open the session transcript without a prompt.
    case session(gatewayID: GatewayID, sessionID: String)
    /// Open the gateway's Connection screen to reconnect.
    case gatewayConnection(GatewayID)
    /// Open the gateways list (removed or unidentifiable gateway).
    case gatewayList
    /// Open the Needs You / home surface.
    case home
}

public struct NotificationTapOutcome: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Opening the request; its state is confirmed by the live read.
        case opening(verified: Bool)
        case resolved
        case expired
        case gatewayDisconnected
        case gatewayRemoved
        case gatewayUnidentified
        case invalid
    }

    public let state: State
    public let destination: NotificationTapDestination
    /// Truthful, non-secret explanation shown when state is not `.opening`.
    public let message: String?
}

public enum NotificationTapResolver {
    /// Decide what a tap opens. Pure; never mutates state and never answers a
    /// request.
    public static func resolve(
        _ target: NotificationTapTarget,
        now: Date,
        gateways: [FleetGateway],
        requestStatus: NotificationRequestStatus
    ) -> NotificationTapOutcome {
        guard OpenedNotificationPayload.isSafeToken(target.sessionID),
              target.requestID.map(OpenedNotificationPayload.isSafeToken) ?? true
        else {
            return .init(state: .invalid, destination: .home, message: "This notification couldn't be opened.")
        }
        guard let gatewayID = target.gatewayID else {
            return .init(
                state: .gatewayUnidentified,
                destination: .gatewayList,
                message: "Fleet couldn't tell which gateway sent this."
            )
        }
        guard let gateway = gateways.first(where: { $0.id == gatewayID }) else {
            return .init(
                state: .gatewayRemoved,
                destination: .gatewayList,
                message: "This gateway was removed from Fleet."
            )
        }
        let isRequestKind = target.kind == .approval || target.kind == .clarify
        guard isRequestKind else {
            return .init(state: .opening(verified: true), destination: .session(gatewayID: gatewayID, sessionID: target.sessionID), message: nil)
        }
        switch requestStatus {
        case .pending:
            return open(target, gatewayID, verified: true)
        case .notPending:
            return .init(
                state: .resolved,
                destination: .session(gatewayID: gatewayID, sessionID: target.sessionID),
                message: "This request was already handled."
            )
        case .unverified:
            if now >= target.expiresAt {
                return .init(
                    state: .expired,
                    destination: .session(gatewayID: gatewayID, sessionID: target.sessionID),
                    message: "This request may have expired. Fleet will show it if it is still waiting."
                )
            }
            if isOffline(gateway.connectionState) {
                return .init(
                    state: .gatewayDisconnected,
                    destination: .gatewayConnection(gatewayID),
                    message: "Reconnect to \(gateway.displayName) to check this request."
                )
            }
            return open(target, gatewayID, verified: false)
        }
    }

    private static func isOffline(_ state: TransportState) -> Bool {
        switch state {
        case .disconnected, .failed: return true
        case .connecting, .connected: return false
        }
    }

    private static func open(_ target: NotificationTapTarget, _ gatewayID: GatewayID, verified: Bool) -> NotificationTapOutcome {
        .init(
            state: .opening(verified: verified),
            destination: .request(gatewayID: gatewayID, sessionID: target.sessionID, requestID: target.requestID),
            message: nil
        )
    }
}
