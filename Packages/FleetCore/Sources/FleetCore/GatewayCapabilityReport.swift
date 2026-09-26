import Foundation

/// P1 (RC-84) — the gateway capability/compatibility report.
///
/// HONESTY CONTRACT (capability-honesty policy, spec §5.5/§14):
/// - A feature is `supported` ONLY on evidence observed from THIS phone
///   (a roster answer, a capability probe, a recorded surface outcome) —
///   never because Fleet ships UI for it.
/// - `unsupported` (the gateway definitively says no), `unavailable` (it
///   failed / could not be reached), and `unknown` (never observed) stay
///   DISTINCT states, each with a human reason where one is known.
/// - No network work happens here: this is a pure projection of evidence
///   the app already holds.
public enum CapabilityAvailability: Hashable, Sendable {
    /// Confirmed working on this phone's current evidence.
    case supported
    /// The gateway definitively does not offer this.
    case unsupported(reason: String)
    /// Offered in principle but currently failing / unreachable.
    case unavailable(reason: String)
    /// No evidence either way yet — fail closed.
    case unknown(reason: String)

    /// Short state word for the report row.
    public var label: String {
        switch self {
        case .supported: return "Supported"
        case .unsupported: return "Not supported"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    /// The human reason, when the state carries one (nil for `supported`).
    public var reason: String? {
        switch self {
        case .supported: return nil
        case .unsupported(let reason), .unavailable(let reason), .unknown(let reason):
            return reason
        }
    }
}

/// The Fleet-managed capability rows the report covers (declaration order is
/// report order).
public enum GatewayCapabilityFeature: String, CaseIterable, Hashable, Sendable {
    case chats
    case bots
    case groups
    case roomLink
    case reactions
    case attachments
    case imageGeneration
    case voice
    case schedules
    case skills
    case memory
    case kanban
    case projects
    case approvals

    /// Human name for the report row.
    public var title: String {
        switch self {
        case .chats: return "Chats"
        case .bots: return "Bots"
        case .groups: return "Groups"
        case .roomLink: return "RoomLink / cross-gateway Groups"
        case .reactions: return "Reactions"
        case .attachments: return "Attachments"
        case .imageGeneration: return "Image generation"
        case .voice: return "Voice"
        case .schedules: return "Schedules"
        case .skills: return "Skills"
        case .memory: return "Memory"
        case .kanban: return "Kanban"
        case .projects: return "Projects"
        case .approvals: return "Approvals"
        }
    }
}

/// Everything the report may truthfully read from this phone's state. Each
/// field is real evidence the app already gathered; absent evidence stays
/// absent (nil / `.unknown`) — never defaulted into a claim.
public struct GatewayCapabilityEvidence: Equatable, Sendable {
    /// Transport capability flags advertised by the gateway (e.g. adopted
    /// from `gateway.ready` / the roster). Kept for the advertised-surface
    /// disclosure; the feature rows below do not infer from it.
    public var advertisedCapabilities: Set<String>
    /// The persisted gateway-level `groups.capabilities` probe result
    /// (F1 rules: `.unknown` never flips either way).
    public var groupsCreate: GroupsCreateCapability
    /// The last roster refresh outcome for this gateway (nil = never ran).
    public var rosterOutcome: GatewayRosterOutcome?
    /// RoomLink negotiation result, when one has actually been attempted
    /// from this phone (nil = not attempted).
    public var roomLinkNegotiated: Bool?
    /// Recorded per-feature observations (the most specific evidence; wins
    /// over structural inference).
    public var observed: [GatewayCapabilityFeature: CapabilityAvailability]

    public init(
        advertisedCapabilities: Set<String> = [],
        groupsCreate: GroupsCreateCapability = .unknown,
        rosterOutcome: GatewayRosterOutcome? = nil,
        roomLinkNegotiated: Bool? = nil,
        observed: [GatewayCapabilityFeature: CapabilityAvailability] = [:]
    ) {
        self.advertisedCapabilities = advertisedCapabilities
        self.groupsCreate = groupsCreate
        self.rosterOutcome = rosterOutcome
        self.roomLinkNegotiated = roomLinkNegotiated
        self.observed = observed
    }
}

/// One rendered report row.
public struct GatewayCapabilityRow: Hashable, Sendable, Identifiable {
    public let feature: GatewayCapabilityFeature
    public let availability: CapabilityAvailability

    public var id: String { feature.rawValue }

    public init(feature: GatewayCapabilityFeature, availability: CapabilityAvailability) {
        self.feature = feature
        self.availability = availability
    }
}

/// The pure policy: maps evidence onto the report rows. Unit-tested in both
/// directions (never infers `supported` without evidence; keeps the four
/// states distinct).
public enum GatewayCapabilityReport {

    /// The full report, in `GatewayCapabilityFeature.allCases` order.
    public static func rows(_ evidence: GatewayCapabilityEvidence) -> [GatewayCapabilityRow] {
        GatewayCapabilityFeature.allCases.map { feature in
            GatewayCapabilityRow(
                feature: feature,
                availability: availability(for: feature, evidence: evidence)
            )
        }
    }

    /// The availability for one feature.
    ///
    /// Precedence: a recorded observation (real use on this phone) outranks
    /// structural evidence; structural evidence outranks "unknown".
    public static func availability(
        for feature: GatewayCapabilityFeature,
        evidence: GatewayCapabilityEvidence
    ) -> CapabilityAvailability {
        if let recorded = evidence.observed[feature] {
            return recorded
        }
        switch feature {
        case .chats, .bots:
            // The roster answer is the one central probe this phone runs
            // against every gateway: `profiles.list` answering proves the
            // session is live and every profile it serves is chat-reachable
            // through the multiplexer connection (P0-7 model).
            switch evidence.rosterOutcome {
            case .loaded:
                return .supported
            case .failed(let status, let detail):
                return .unavailable(reason: detail ?? statusReason(status))
            case nil:
                return .unknown(reason: "Not checked from this phone yet — refresh Bots to probe the gateway.")
            }
        case .groups:
            switch evidence.groupsCreate {
            case .supported:
                return .supported
            case .unsupported:
                return .unsupported(reason: "The gateway reports it does not offer hosted Group creation (groups.create).")
            case .unknown:
                return .unknown(reason: "Group creation has not been probed from this phone yet.")
            }
        case .roomLink:
            if let negotiated = evidence.roomLinkNegotiated {
                return negotiated
                    ? .supported
                    : .unsupported(reason: "RoomLink negotiation failed from this phone.")
            }
            return .unknown(reason: "RoomLink is negotiated per cross-gateway Group; not probed yet.")
        case .reactions, .attachments, .imageGeneration, .voice, .schedules, .skills, .memory, .kanban, .projects, .approvals:
            return .unknown(reason: "Not yet observed from this phone.")
        }
    }

    /// The compact counts line, e.g. "2 supported · 1 not supported · 11
    /// unknown". Zero-count states are omitted; an all-zero report (empty
    /// rows) returns "".
    public static func summary(_ rows: [GatewayCapabilityRow]) -> String {
        var supported = 0
        var unsupported = 0
        var unavailable = 0
        var unknown = 0
        for row in rows {
            switch row.availability {
            case .supported: supported += 1
            case .unsupported: unsupported += 1
            case .unavailable: unavailable += 1
            case .unknown: unknown += 1
            }
        }
        var parts: [String] = []
        if supported > 0 { parts.append("\(supported) supported") }
        if unsupported > 0 { parts.append("\(unsupported) not supported") }
        if unavailable > 0 { parts.append("\(unavailable) unavailable") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.joined(separator: " · ")
    }

    /// Non-secret fallback reason for a failed roster outcome without a
    /// detail string.
    private static func statusReason(_ status: GatewayStatus) -> String {
        switch status {
        case .authenticationRequired:
            return "The gateway requires authentication."
        case .unsupported:
            return "The endpoint did not answer as the gateway API."
        case .degraded:
            return "The gateway is answering but degraded."
        case .offline, .connecting, .online:
            return "The gateway did not answer its roster."
        }
    }
}