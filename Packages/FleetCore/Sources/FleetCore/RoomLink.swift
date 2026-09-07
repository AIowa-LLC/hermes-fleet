import Foundation

/// TRUE BOTS MODE slice 5 (D19) — RoomLink domain: feature negotiation,
/// installation identity, authority gateway/epoch, execution policy, grants,
/// route registration/revoke, replication/replay, promotion prerequisites
/// and explicit confirmations.
///
/// Every shape here mirrors upstream source at 08b140d (NOT docs):
/// - `groups.capabilities` room_link catalog — tui_gateway/methods_groups.py:232-238
/// - catalog mapping — gateway/hosted_room_peer.py:226-284 (link_modes "direct"
///   only, text=true, attachments=false, execution_policy v1 with sha256
///   digests)
/// - grants — hosted_room_peer.py:390-437 (HMAC token; TTL 60..86400s)
/// - peer.register validation strings — methods_groups.py:297-343
/// - promote confirm handshake — methods_groups.py:508-517 (4118) and
///   hosted_room_replicas.py:241-286
///
/// Honesty rules (binding): when the gateway does not advertise RoomLink the
/// UI renders the unsupported state with the gateway's own reason — never a
/// fake cross-machine surface. The iPhone is foreground-sockets only: no copy
/// may claim background couriering (`persistent_process` is the gateway's
/// truth about ITSELF, not about this client).

// MARK: - Negotiation

/// Why a gateway reports RoomLink disabled (methods_groups.py:232-238 emits
/// exactly these two; anything else decodes as `.other` preserving the wire
/// string — unknown strings are never rewritten).
public enum RoomLinkDisabledReason: Hashable, Sendable {
    /// Gateway durable run storage is not configured.
    case durableRunStorageRequired
    /// Gateway could not load its RoomLink grant secret.
    case gatewayRoomlinkSecretUnavailable
    /// Unknown reason string, preserved verbatim.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "durable_run_storage_required": self = .durableRunStorageRequired
        case "gateway_roomlink_secret_unavailable": self = .gatewayRoomlinkSecretUnavailable
        default: self = .other(wireValue)
        }
    }

    /// Plain-language explanation rendered in the unsupported state.
    public var explanation: String {
        switch self {
        case .durableRunStorageRequired:
            return "Gateway storage setup needed before rooms can link across machines."
        case .gatewayRoomlinkSecretUnavailable:
            return "Gateway security config needed before rooms can link across machines."
        case .other(let raw):
            return "This gateway can't link rooms across machines (\(raw))."
        }
    }
}

/// The RoomLink endpoint as advertised inside the catalog
/// (hosted_room_peer.py:237-241, 276-284).
public struct RoomLinkEndpoint: Hashable, Sendable {
    public let available: Bool
    /// https anywhere, or loopback http (transport_security "loopback").
    public let url: String?
    public let transportSecurity: String?
    /// "not_configured" | "invalid_configuration" when unavailable.
    public let unavailableReason: String?

    public init(
        available: Bool, url: String? = nil,
        transportSecurity: String? = nil, unavailableReason: String? = nil
    ) {
        self.available = available
        self.url = url
        self.transportSecurity = transportSecurity
        self.unavailableReason = unavailableReason
    }
}

/// Execution policy snapshot carried in the catalog
/// (gateway/hosted_room_execution_policy.py:15, 44-65; POLICY_VERSION 1).
/// The digest binds the policy; a changed digest during peer registration
/// fails closed upstream ("target capability catalog changed during setup").
public struct RoomLinkExecutionPolicy: Hashable, Sendable {
    public let version: Int
    public let targetProfile: String
    public let enabledToolsets: [String]
    /// "manual" | "smart" | "off" ("off" is refused for remote targets).
    public let approvalMode: String
    public let maxIterations: Int
    /// sha256 hex 64 of the canonical policy JSON.
    public let policyDigest: String

    public init(
        version: Int, targetProfile: String, enabledToolsets: [String],
        approvalMode: String, maxIterations: Int, policyDigest: String
    ) {
        self.version = version
        self.targetProfile = targetProfile
        self.enabledToolsets = enabledToolsets
        self.approvalMode = approvalMode
        self.maxIterations = maxIterations
        self.policyDigest = policyDigest
    }
}

/// The negotiated RoomLink catalog (the gateway's own advertisement).
/// Direct mode, text-only — `attachments` is false upstream and the composer
/// must hide the attachment tray in cross-machine rooms, honestly.
public struct RoomLinkNegotiation: Hashable, Sendable {
    /// `install:<install_id>` — the installation identity of the authority.
    public let authorityGatewayID: String
    public let enabled: Bool
    public let disabledReason: RoomLinkDisabledReason?
    public let profile: String?
    public let protocolVersion: Int
    public let installationID: String
    public let linkModes: [String]
    public let persistentProcess: Bool
    public let textOnly: Bool
    public let attachmentsSupported: Bool
    public let catalogDigest: String
    public let executionPolicy: RoomLinkExecutionPolicy?
    public let endpoint: RoomLinkEndpoint?
    /// The gateway's advertised groups.* methods (gates every action).
    public let methods: [String]

    public init(
        authorityGatewayID: String,
        enabled: Bool,
        disabledReason: RoomLinkDisabledReason? = nil,
        profile: String? = nil,
        protocolVersion: Int = 0,
        installationID: String = "",
        linkModes: [String] = [],
        persistentProcess: Bool = false,
        textOnly: Bool = true,
        attachmentsSupported: Bool = false,
        catalogDigest: String = "",
        executionPolicy: RoomLinkExecutionPolicy? = nil,
        endpoint: RoomLinkEndpoint? = nil,
        methods: [String] = []
    ) {
        self.authorityGatewayID = authorityGatewayID
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.profile = profile
        self.protocolVersion = protocolVersion
        self.installationID = installationID
        self.linkModes = linkModes
        self.persistentProcess = persistentProcess
        self.textOnly = textOnly
        self.attachmentsSupported = attachmentsSupported
        self.catalogDigest = catalogDigest
        self.executionPolicy = executionPolicy
        self.endpoint = endpoint
        self.methods = methods
    }

    /// Method-level gates (the gateway's `methods` list is the truth).
    public func supports(_ method: String) -> Bool {
        enabled && methods.contains(method)
    }

    /// Direct-mode support (the only link mode upstream ever advertises).
    public var supportsDirectMode: Bool { linkModes.contains("direct") }

    /// Catalog-unchanged check for peer registration: the digest the target
    /// advertised at invite time must equal the digest at register time
    /// (upstream fails closed with "target capability catalog changed during
    /// setup" — methods_groups.py:332).
    public static func catalogUnchanged(
        advertised: RoomLinkNegotiation, observed: RoomLinkNegotiation
    ) -> Bool {
        advertised.catalogDigest == observed.catalogDigest
            && !advertised.catalogDigest.isEmpty
    }

    /// Honest cross-machine summary: direct + text-only + endpoint security.
    public var transportSummary: String {
        guard enabled else { return "Unavailable" }
        var parts: [String] = ["Direct link"]
        if let security = endpoint?.transportSecurity, endpoint?.available == true {
            parts.append(security == "tls" ? "TLS" : "loopback")
        }
        parts.append(textOnly ? "text only" : "text + attachments")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Grants (D19)

/// A peer grant minted by `groups.peer.invite`. TTL bounds are upstream
/// constants: 60...86400 seconds (methods_groups.py:250-279); dispatch
/// permission caps at 24h even when the status permission lives longer
/// (hosted_room_peer.py:398-399).
public struct RoomLinkGrant: Hashable, Sendable, Identifiable {
    public static let minTTLSeconds = 60.0
    public static let maxTTLSeconds = 86400.0

    public enum Permission: String, Hashable, Sendable, CaseIterable {
        case approve, dispatch, status, stop
    }

    public let id: String
    /// The bearer token — NEVER rendered in full (capability token; display
    /// uses `displayToken`).
    public let token: String
    public let roomID: String?
    public let memberID: String?
    public let targetProfile: String
    public let permissions: [Permission]
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: String, token: String, roomID: String?, memberID: String?,
        targetProfile: String, permissions: [Permission],
        issuedAt: Date, expiresAt: Date
    ) {
        self.id = id
        self.token = token
        self.roomID = roomID
        self.memberID = memberID
        self.targetProfile = targetProfile
        self.permissions = permissions
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// Non-secret token rendering (last 6 chars only).
    public var displayToken: String {
        guard token.count > 6 else { return "••••" }
        return "••••" + String(token.suffix(6))
    }

    public func isValid(at date: Date = Date()) -> Bool {
        date >= issuedAt && date < expiresAt
    }

    /// True in the last 10% of the grant's lifetime (refresh affordance).
    public func isNearExpiry(at date: Date = Date()) -> Bool {
        guard expiresAt > issuedAt else { return false }
        let total = expiresAt.timeIntervalSince(issuedAt)
        let remaining = expiresAt.timeIntervalSince(date)
        return remaining <= total * 0.1
    }

    /// TTL validation (exact upstream error on violation:
    /// "ttl_seconds must be between 60 and 86400").
    public static func validate(ttlSeconds: Double) -> String? {
        guard ttlSeconds >= minTTLSeconds, ttlSeconds <= maxTTLSeconds else {
            return "ttl_seconds must be between 60 and 86400"
        }
        return nil
    }

    /// Preset pickers shown in the invite sheet (seconds).
    public static let ttlPresets: [(label: String, seconds: Double)] = [
        ("1 hour", 3600),
        ("8 hours", 28800),
        ("24 hours", 86400),
    ]
}

// MARK: - Peer routes (D19)

/// A registered RoomLink peer route for a room member
/// (`groups.peer.register` → {registered, mode, transport_security,
/// target_install_id, target_profile}; route status lifecycle
/// ready | needs_reauthorization | unavailable — hosted_room_service.py:289-295).
public struct RoomPeerRoute: Hashable, Sendable, Identifiable {
    public enum Status: String, Hashable, Sendable {
        case ready
        case needsReauthorization = "needs_reauthorization"
        case unavailable
    }

    public let roomID: String
    public let memberID: String
    public let targetInstallID: String
    public let targetProfile: String
    /// Only "direct" is ever registered upstream.
    public let mode: String
    public let transportSecurity: String
    public let status: Status

    public var id: String { "\(roomID)#\(memberID)" }

    public init(
        roomID: String, memberID: String, targetInstallID: String,
        targetProfile: String, mode: String, transportSecurity: String,
        status: Status = .ready
    ) {
        self.roomID = roomID
        self.memberID = memberID
        self.targetInstallID = targetInstallID
        self.targetProfile = targetProfile
        self.mode = mode
        self.transportSecurity = transportSecurity
        self.status = status
    }
}

/// Typed peer-registration refusals. Messages are the EXACT upstream
/// validation strings (methods_groups.py:297-343, error code 5120) — the
/// adapter matches on them; anything else decodes `.other`.
public enum RoomLinkRegistrationRefusal: Error, Hashable, Sendable, Equatable {
    case targetProtocolUnsupported        // "target does not support RoomLink protocol v2"
    case directModeUnsupported            // "target does not support a direct RoomLink"
    case catalogChangedDuringSetup        // "target capability catalog changed during setup"
    case grantScopeMismatch               // "room grant scope does not match this route"

    public init?(wireMessage: String) {
        switch wireMessage {
        case "target does not support RoomLink protocol v2":
            self = .targetProtocolUnsupported
        case "target does not support a direct RoomLink":
            self = .directModeUnsupported
        case "target capability catalog changed during setup":
            self = .catalogChangedDuringSetup
        case "room grant scope does not match this route":
            self = .grantScopeMismatch
        default:
            return nil
        }
    }

    /// Plain-language explanation (what happened + what to do).
    public var explanation: String {
        switch self {
        case .targetProtocolUnsupported:
            return "The other gateway doesn't speak this RoomLink version yet — update it, then link again."
        case .directModeUnsupported:
            return "The other gateway doesn't accept direct links. Direct is the only supported mode."
        case .catalogChangedDuringSetup:
            return "The other gateway's capabilities changed mid-setup. Start the link again."
        case .grantScopeMismatch:
            return "The grant doesn't cover this room and member. Invite again and retry immediately."
        }
    }
}

// MARK: - Replication / promotion (D19)

/// `groups.replica_state` normalized (hosted_room_replicas.py:184-195).
public struct RoomReplicaState: Hashable, Sendable {
    public let roomID: String
    public let name: String
    public let authorityGatewayID: String
    public let authorityEpoch: Int
    public let lastSeq: Int
    public let latestSeq: Int
    public let eventBytes: Int
    public let createdAt: Double
    public let updatedAt: Double

    public init(
        roomID: String, name: String, authorityGatewayID: String,
        authorityEpoch: Int, lastSeq: Int, latestSeq: Int,
        eventBytes: Int, createdAt: Double, updatedAt: Double
    ) {
        self.roomID = roomID
        self.name = name
        self.authorityGatewayID = authorityGatewayID
        self.authorityEpoch = authorityEpoch
        self.lastSeq = lastSeq
        self.latestSeq = latestSeq
        self.eventBytes = eventBytes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Caught-up = the replica has stored every event the authority logged.
    public var isCaughtUp: Bool { lastSeq >= latestSeq }

    /// Replay progress fraction 0...1 (never fabricated beyond 1).
    public var progress: Double {
        guard latestSeq > 0 else { return 1 }
        return min(1, Double(lastSeq) / Double(latestSeq))
    }
}

/// `groups.replicate` receipt (hosted_room_replicas.py:179-181).
public struct RoomReplicateReceipt: Hashable, Sendable {
    public let roomID: String
    public let storedSeq: Int
    public let ingested: Int
    public let authorityGatewayID: String
    public let authorityEpoch: Int
    public let caughtUp: Bool

    public init(
        roomID: String, storedSeq: Int, ingested: Int,
        authorityGatewayID: String, authorityEpoch: Int, caughtUp: Bool
    ) {
        self.roomID = roomID
        self.storedSeq = storedSeq
        self.ingested = ingested
        self.authorityGatewayID = authorityGatewayID
        self.authorityEpoch = authorityEpoch
        self.caughtUp = caughtUp
    }
}

/// `groups.promote` receipt (hosted_room_replicas.py:241-244): this gateway
/// BECOMES the authority at epoch+1; the previous authority is named — the
/// confirmation UI must say who loses authority.
public struct RoomPromotionReceipt: Hashable, Sendable {
    public let roomID: String
    public let authorityGatewayID: String
    public let authorityEpoch: Int
    public let previousGatewayID: String
    public let previousEpoch: Int
    public let claimSeq: Int
    public let latestSeq: Int
}

/// Pure promotion-prerequisite check (D19). Upstream gates:
/// - `groups.promote` REQUIRES `confirm: true` (4118 otherwise,
///   methods_groups.py:513-515: "promotion requires confirm=true
///   acknowledging the previous authority can no longer commit")
/// - The replica must be caught up (last_seq >= latest_seq) before promoting
///   makes sense — promoting a stale replica forks the room.
public enum RoomPromotionReadiness: Hashable, Sendable {
    case ready(previousGatewayID: String, previousEpoch: Int)
    case replicaNotCaughtUp(lastSeq: Int, latestSeq: Int)
    case roomNotLocal
    case unknown

    public static func evaluate(
        replica: RoomReplicaState?, localAuthorityGatewayID: String?
    ) -> RoomPromotionReadiness {
        guard let replica else { return .unknown }
        guard let localAuthorityGatewayID,
              replica.authorityGatewayID == localAuthorityGatewayID else {
            return .roomNotLocal
        }
        guard replica.isCaughtUp else {
            return .replicaNotCaughtUp(lastSeq: replica.lastSeq, latestSeq: replica.latestSeq)
        }
        return .ready(previousGatewayID: replica.authorityGatewayID, previousEpoch: replica.authorityEpoch)
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The explicit-confirmation copy naming the previous authority (never
    /// generic "are you sure?" — D19 mandates naming who loses authority).
    public var confirmationTitle: String? {
        if case .ready(let previous, let epoch) = self {
            return "Take over this room from \(previous) (epoch \(epoch))?"
        }
        return nil
    }

    public var confirmationMessage: String {
        switch self {
        case .ready:
            return "Promotion is a takeover: the previous authority can no longer commit once you take over. The room's authority epoch advances by one."
        case .replicaNotCaughtUp(let last, let latest):
            return "This copy is behind (event \(last) of \(latest)) — replay the room first. Promoting a stale copy would fork the room."
        case .roomNotLocal:
            return "This room's replica is not on this gateway."
        case .unknown:
            return "Replica state is not loaded yet."
        }
    }
}

// MARK: - Command seam (implemented app-side / FleetNetworking-side)

/// RoomLink operations for one gateway — the exact `groups.peer.*` +
/// replicate/promote/demote surface. Declared in FleetCore so FleetUI never
/// imports FleetNetworking (M0 boundary).
public protocol RoomLinkCommanding: Sendable {
    /// `groups.capabilities` → negotiated RoomLink truth for this gateway.
    func negotiate() async throws -> RoomLinkNegotiation
    /// `groups.peer.invite` on the TARGET gateway (mints the scoped grant).
    func invite(
        roomID: String?, memberID: String?, ttlSeconds: Double
    ) async throws -> RoomLinkGrant
    /// `groups.peer.register` on the room's gateway (publishes the route;
    /// validates catalog unchanged + grant scope).
    func registerPeer(
        roomID: String, memberID: String, grant: RoomLinkGrant,
        targetURL: String, catalogDigest: String
    ) async throws -> RoomPeerRoute
    /// `groups.peer.revoke`.
    func revoke(grant: RoomLinkGrant) async throws
    /// Registered peer routes for a room (from driver status peer_routes).
    func peerRoutes(roomID: String) async throws -> [RoomPeerRoute]
    /// `groups.replica_state`.
    func replicaState(roomID: String) async throws -> RoomReplicaState?
    /// `groups.replicate` with the current durable log page.
    func replicate(roomID: String) async throws -> RoomReplicateReceipt
    /// `groups.promote` — REQUIRES an explicit user confirmation; the seam
    /// must forward `confirm: true` only after the typed confirmation.
    func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt
    /// `groups.demote` with the observed authority (idempotent).
    func demote(roomID: String, observedGatewayID: String, observedEpoch: Int) async throws
}
