import Foundation

/// Provenance of a group room: which generation owns its execution.
///
/// Tony's binding addendum: the two room generations must never be conflated.
/// Hosted rooms are executed by the gateway's `groups.*` surface
/// (tui_gateway/methods_groups.py); desktopLegacy rooms are plugin-local to
/// Hermes Desktop and reach Fleet only through the bounded display
/// projection under default-profile ui_meta key `hermes-bots-groups`
/// (apps/desktop group-chat.ts:67-74). There is NO upstream bridge
/// (inspection-desktop-bots.md §9 Q8) — provenance is permanent per room.
public enum RoomProvenance: String, Hashable, Sendable, Codable {
    /// Gateway-hosted authoritative execution (durable log, epochs, replay).
    case hosted
    /// Desktop plugin-local room, observable via the ui_meta projection only.
    case desktopLegacy
}

/// Per-room mutation capabilities. Computed from provenance + gateway
/// capability truth — never hardcoded per screen, never all-true for legacy
/// rooms (addendum: "capability-disabled mutations never issue writes").
public struct RoomCapabilities: Hashable, Sendable, Codable {
    public var canSend: Bool
    public var canRename: Bool
    public var canDisband: Bool
    public var canStop: Bool
    public var canRetry: Bool
    public var canApprove: Bool
    public var canReplay: Bool
    public var canManageMembers: Bool

    public init(
        canSend: Bool,
        canRename: Bool,
        canDisband: Bool,
        canStop: Bool,
        canRetry: Bool,
        canApprove: Bool,
        canReplay: Bool,
        canManageMembers: Bool
    ) {
        self.canSend = canSend
        self.canRename = canRename
        self.canDisband = canDisband
        self.canStop = canStop
        self.canRetry = canRetry
        self.canApprove = canApprove
        self.canReplay = canReplay
        self.canManageMembers = canManageMembers
    }

    /// Hosted rooms: interactive per the gateway's advertised `methods` list
    /// and driver availability (`groups.capabilities`).
    public static func hosted(
        methods: [String], driverAvailable: Bool
    ) -> RoomCapabilities {
        func has(_ m: String) -> Bool { driverAvailable && methods.contains(m) }
        return RoomCapabilities(
            canSend: has("groups.send"),
            canRename: has("groups.rename"),
            canDisband: has("groups.disband"),
            canStop: has("groups.stop"),
            canRetry: has("groups.retry"),
            canApprove: has("groups.approve"),
            canReplay: has("groups.log"),
            canManageMembers: has("groups.create") || has("groups.peer.invite")
        )
    }

    /// Legacy Desktop rooms: strictly observational. No supported mutation
    /// path exists (addendum Q7: no gateway RPC can safely mutate a
    /// Desktop-owned room) — every capability is false.
    public static let desktopLegacyObservational = RoomCapabilities(
        canSend: false,
        canRename: false,
        canDisband: false,
        canStop: false,
        canRetry: false,
        canApprove: false,
        canReplay: false,
        canManageMembers: false
    )
}

/// Durable identity of a room: provenance + owning gateway + generation-
/// specific key. Two rooms with the SAME NAME but different provenance (or
/// different gateways) are structurally distinct identities — the type makes
/// the addendum's "never merge by name" rule impossible to violate by
/// construction, since equality requires all three components.
public struct FleetRoomID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let provenance: RoomProvenance
    public let gatewayID: GatewayID
    /// Hosted: the gateway `room_id`. desktopLegacy: the projection key
    /// (`id:<roomId>` or legacy `name:<name>`) — kept verbatim so the two
    /// legacy key generations never collapse into one namespace.
    public let key: String

    public init(provenance: RoomProvenance, gatewayID: GatewayID, key: String) {
        self.provenance = provenance
        self.gatewayID = gatewayID
        self.key = key
    }

    public var description: String {
        "\(provenance.rawValue):\(gatewayID.rawValue):\(key)"
    }

    /// Stable storage identity.
    public var storageKey: String { description }
}

/// A normalized room row as rendered in the roster/rooms list. Fields are
/// optional by design: a legacy projection carries only what Desktop chose to
/// mirror — Fleet displays ONLY what is present and never invents state.
public struct FleetRoom: Identifiable, Hashable, Sendable {
    public let id: FleetRoomID
    public var name: String
    /// Display members (≤6 on legacy projections; source-qualified where the
    /// projection carries connection identity).
    public var members: [FleetRoomMember]
    /// Bounded recent transcript window (legacy: last ≤16 entries; hosted:
    /// last fetched log page). NOT the durable log for legacy rooms.
    public var recentLog: [FleetRoomMessage]
    /// Room image (data URL) when the projection carries one.
    public var image: String?
    /// Monotonic revision (legacy mirror revision / hosted room revision).
    public var revision: Int
    /// Tombstone: a deleted/disbanded room never renders and a stale mirror
    /// must not resurrect it (id-keyed tombstones are FINAL).
    public var isDeleted: Bool
    /// Hosted-only fields; nil for legacy projections.
    public var hosted: HostedRoomState?

    public var roomID: FleetRoomID { id }

    public init(
        id: FleetRoomID,
        name: String,
        members: [FleetRoomMember] = [],
        recentLog: [FleetRoomMessage] = [],
        image: String? = nil,
        revision: Int = 0,
        isDeleted: Bool = false,
        hosted: HostedRoomState? = nil
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.recentLog = recentLog
        self.image = image
        self.revision = revision
        self.isDeleted = isDeleted
        self.hosted = hosted
    }

    /// Mutation capabilities for this room.
    public var capabilities: RoomCapabilities {
        guard !isDeleted else { return .desktopLegacyObservational }
        switch id.provenance {
        case .hosted:
            if let hosted, let caps = hosted.advertisedMethods {
                return .hosted(methods: caps, driverAvailable: hosted.driverAvailable)
            }
            // Unknown capability truth: fail closed to observational.
            return .desktopLegacyObservational
        case .desktopLegacy:
            return .desktopLegacyObservational
        }
    }

    /// Honest observational label for legacy rooms (addendum: present "a
    /// normal supported observational room labeled Managed by Hermes
    /// Desktop; not a broken screen").
    public var isManagedByDesktop: Bool {
        id.provenance == .desktopLegacy
    }
}

/// Hosted-room state fields (from `groups.list`/`groups.state` rows).
public struct HostedRoomState: Hashable, Sendable {
    public var authorityGatewayID: String
    public var authorityEpoch: Int
    public var latestSeq: Int?
    public var createdAt: Double?
    public var updatedAt: Double?
    public var disbandedAt: Double?
    /// The gateway's advertised groups methods (from groups.capabilities) —
    /// nil when capability truth has not been fetched (fail closed).
    public var advertisedMethods: [String]?
    public var driverAvailable: Bool

    public init(
        authorityGatewayID: String,
        authorityEpoch: Int,
        latestSeq: Int? = nil,
        createdAt: Double? = nil,
        updatedAt: Double? = nil,
        disbandedAt: Double? = nil,
        advertisedMethods: [String]? = nil,
        driverAvailable: Bool = false
    ) {
        self.authorityGatewayID = authorityGatewayID
        self.authorityEpoch = authorityEpoch
        self.latestSeq = latestSeq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.disbandedAt = disbandedAt
        self.advertisedMethods = advertisedMethods
        self.driverAvailable = driverAvailable
    }
}

/// A room member as carried by either generation. Legacy projections may
/// carry connection identity (connectionId/Label/Kind, sourceScoped);
/// hosted members are source-qualified profiles on the authority gateway
/// unless addressing a RoomLink peer.
public struct FleetRoomMember: Hashable, Sendable, Codable {
    public var name: String
    public var handle: String?
    public var connectionID: String?
    public var connectionLabel: String?
    public var sourceScoped: Bool

    public init(
        name: String,
        handle: String? = nil,
        connectionID: String? = nil,
        connectionLabel: String? = nil,
        sourceScoped: Bool = false
    ) {
        self.name = name
        self.handle = handle
        self.connectionID = connectionID
        self.connectionLabel = connectionLabel
        self.sourceScoped = sourceScoped
    }
}

/// One entry of a room transcript window.
public struct FleetRoomMessage: Hashable, Sendable, Codable, Identifiable {
    public enum ActorKind: String, Hashable, Sendable, Codable {
        case member
        case user
    }

    public struct Actor: Hashable, Sendable, Codable {
        public var kind: ActorKind
        public var name: String
        public var source: String?

        public init(kind: ActorKind, name: String, source: String? = nil) {
            self.kind = kind
            self.name = name
            self.source = source
        }
    }

    public let id: String
    public var from: Actor
    public var text: String
    /// Epoch milliseconds on the legacy projection; hosted events carry
    /// `created_at` epoch seconds — normalized here by the decoder.
    public var at: Double
    public var thread: String?

    public init(id: String, from: Actor, text: String, at: Double, thread: String? = nil) {
        self.id = id
        self.from = from
        self.text = text
        self.at = at
        self.thread = thread
    }
}
