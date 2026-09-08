import Foundation

/// FOS-4 (SPEC §7 Needs You / §17 summary envelope) — one CONFIRMED,
/// already-observed intervention item for the Fleet Home "Needs You" section.
///
/// Truth contract (SPEC §7 "Needs You eligibility"):
/// - Items exist only from ALREADY-OBSERVED authoritative signals — a
///   classified live gateway failure, or an object-local observation (room
///   driver status) this phone actually read. Nothing here polls; the Home
///   never fans out `groups.state` per room or `session.list` per bot.
/// - Identity is the dedupe key: one item per gateway/auth episode, and room
///   items key on request/task/member/generation so the same pending request
///   never counts twice (SPEC §7 information-priority rule 1).
/// - Previews are NAVIGATION, never approval buttons: `destination` names the
///   owning screen; confirmation context lives there (SPEC §7).
public struct FleetAttentionItem: Identifiable, Equatable, Sendable {
    /// Where reviewing the item navigates. FleetUI maps this onto
    /// `FleetScreen`; FleetCore owns the vocabulary so aggregation stays
    /// UI-free and hermetically testable.
    public enum Destination: Equatable, Sendable {
        /// The gateway's authentication surface (sign-in).
        case gatewayAuthentication(GatewayID)
        /// The gateway's Connection screen (endpoint/auth/diagnostics).
        case gatewayConnection(GatewayID)
        /// The exact room that owns the pending action (review revalidates
        /// before any write).
        case room(FleetRoomID)
    }

    /// Reason class of the item (drives copy and priority ordering).
    public enum Kind: Equatable, Sendable {
        /// Gateway auth-required — a classified live failure (one per
        /// gateway/auth episode).
        case gatewayAuthRequired
        /// Unsupported/misconfigured endpoint the failure identifies as a
        /// user-actionable setup problem (e.g. the surface-doctor's
        /// "Hermes server on the wrong port" marker).
        case gatewayConfigProblem
        /// Room driver pending approval (fresh `groups.state` observation of
        /// an OPENED room — identity carries request/task/member/generation).
        case roomApproval
        /// Room pending retry that currently calls for an operator action.
        case roomRetry
        /// Room driver blocked (label "Review blocked Group" when no reason).
        case roomDriverBlocked
    }

    /// Stable dedupe identity — kind + source gateway + the exact
    /// request/task/generation identity where supplied.
    public let id: String
    public let kind: Kind
    public let gatewayID: GatewayID
    /// Human title (SPEC §17 attention envelope: human description).
    public let title: String
    public let detail: String?
    public let observedAt: Date
    public let destination: Destination

    public init(
        id: String,
        kind: Kind,
        gatewayID: GatewayID,
        title: String,
        detail: String? = nil,
        observedAt: Date,
        destination: Destination
    ) {
        self.id = id
        self.kind = kind
        self.gatewayID = gatewayID
        self.title = title
        self.detail = detail
        self.observedAt = observedAt
        self.destination = destination
    }

    /// SPEC §7 priority: approval/judgment first, then auth/config block,
    /// then operator-actionable work. Within a class: oldest first, then
    /// stable id.
    public static func prioritySort(_ lhs: FleetAttentionItem, _ rhs: FleetAttentionItem) -> Bool {
        let lRank = lhs.kind.priorityRank
        let rRank = rhs.kind.priorityRank
        if lRank != rRank { return lRank < rRank }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        return lhs.id < rhs.id
    }
}

extension FleetAttentionItem.Kind {
    /// Lower sorts first (higher priority).
    var priorityRank: Int {
        switch self {
        case .roomApproval, .roomDriverBlocked: return 0
        case .gatewayAuthRequired, .gatewayConfigProblem: return 1
        case .roomRetry: return 2
        }
    }
}

/// Pure projection of ALREADY-OBSERVED gateway signals onto Needs You items
/// (FOS-4, SPEC §7). Stateless: callers pass the latest union-roster
/// snapshot; nothing here performs I/O.
public enum FleetAttentionProjection {

    /// Build the gateway-derived items from one roster snapshot.
    ///
    /// Eligibility (SPEC §7 Needs You table):
    /// - `failed(.authenticationRequired)` → one auth item per gateway.
    /// - `failed(.unsupported)` whose detail carries the surface-doctor
    ///   marker (the endpoint ANSWERED but is a Hermes server on the wrong
    ///   port — a user-actionable repair) → one config item.
    /// - `failed(.offline)` / `failed(.degraded)` → NOT attention (status/
    ///   coverage only; no explicit failed operation with a manual remedy).
    public static func gatewayItems(
        gateways: [FleetGateway],
        snapshot: FleetRosterSnapshot?,
        now: Date = Date()
    ) -> [FleetAttentionItem] {
        guard let snapshot else { return [] }
        var items: [FleetAttentionItem] = []
        for gateway in gateways {
            guard case .failed(let status, let detail) = snapshot.outcome(for: gateway.id) else {
                continue
            }
            switch status {
            case .authenticationRequired:
                items.append(FleetAttentionItem(
                    id: "auth|\(gateway.id.rawValue)",
                    kind: .gatewayAuthRequired,
                    gatewayID: gateway.id,
                    title: "Sign in to \(gateway.displayName)",
                    detail: "Authentication required",
                    observedAt: now,
                    destination: .gatewayAuthentication(gateway.id)))
            case .unsupported:
                // Only actionable when the failure NAMES the mix-up (the
                // surface-doctor marker). A plain unsupported answer is a
                // status fact, not a repair item.
                if let detail, detail.contains(FleetAttentionProjection.surfaceDoctorMarker) {
                    items.append(FleetAttentionItem(
                        id: "config|\(gateway.id.rawValue)",
                        kind: .gatewayConfigProblem,
                        gatewayID: gateway.id,
                        title: "Fix \(gateway.displayName)'s endpoint",
                        detail: "A Hermes server answered, but on the wrong port",
                        observedAt: now,
                        destination: .gatewayConnection(gateway.id)))
                }
            case .offline, .degraded, .online, .connecting:
                // Not eligible: transient/status classes stay in connection
                // coverage (SPEC §7 — escalate only with an explicit failed
                // operation and a useful manual remedy).
                break
            }
        }
        return items
    }

    /// The H2 surface-doctor marker appended to `.unsupported` failure
    /// details by `GatewaySurfaceDoctor` (non-secret copy hint). Mirrored
    /// from `GatewaySurfaceDoctorDetail.hermesServerMarker` — FleetCore
    /// cannot see FleetNetworking, so the literal stays single-sourced HERE
    /// (the transport layer's FleetCore dependency guarantees drift shows
    /// up as a failing test, not a silent copy change).
    public static let surfaceDoctorMarker = "/health: hermes-agent"
}

/// Coverage truth for the Needs You section (SPEC §7): whether the observed
/// item set can claim to be the whole inbox. Partial coverage must render
/// "N known items" — never a complete-inbox implication.
public struct FleetAttentionCoverage: Equatable, Sendable {
    /// Every registered gateway has a roster outcome this refresh.
    public let allGatewaysClassified: Bool

    public init(allGatewaysClassified: Bool) {
        self.allGatewaysClassified = allGatewaysClassified
    }

    /// Convenience: compute from a snapshot over the registered fleet.
    public static func compute(gateways: [FleetGateway], snapshot: FleetRosterSnapshot?) -> FleetAttentionCoverage {
        guard let snapshot else { return FleetAttentionCoverage(allGatewaysClassified: false) }
        let classified = gateways.allSatisfy { snapshot.outcome(for: $0.id) != nil }
        return FleetAttentionCoverage(allGatewaysClassified: classified)
    }
}
