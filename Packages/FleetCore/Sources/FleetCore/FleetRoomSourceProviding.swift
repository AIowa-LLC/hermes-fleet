import Foundation

/// FleetUI-facing seam for a gateway's room source (both provenances,
/// unioned). The concrete `GatewayRoomSource` lives app-side; FleetUI
/// depends only on this abstraction (module boundary).
public protocol FleetRoomSourceProviding: Sendable {
    /// All live rooms visible through this gateway (hosted + desktop legacy,
    /// identities never merged). Best-effort per provenance: a failing
    /// source contributes nothing rather than failing the whole call.
    func rooms() async -> [FleetRoom]

    /// Gateway-level `groups.create` capability (F1: this is a GATEWAY
    /// property from `groups.capabilities`, not a property of any room row —
    /// a fully capable gateway with zero hosted rooms must still allow
    /// creating the FIRST room). Default `.unknown` = fail closed: a source
    /// that cannot answer (legacy projection only, no probe yet) must not
    /// flip the create gate either way.
    func createRoomCapability() async -> GroupsCreateCapability
}

extension FleetRoomSourceProviding {
    /// Fail-closed default: unprobed sources report no capability truth.
    public func createRoomCapability() async -> GroupsCreateCapability {
        .unknown
    }
}

/// Gateway-level truth for the Create Room gate (F1). Derived from the
/// gateway's own `groups.capabilities` probe — never from a room row's
/// advertisedMethods (zero-room first-use gate bug).
public enum GroupsCreateCapability: Hashable, Sendable {
    /// The gateway advertises `groups.create` with the room driver
    /// available — the Create Room entry is offered even when the gateway
    /// currently hosts zero rooms (fresh-gateway first use).
    case supported
    /// Definitively no `groups.create` / no driver (or old gateway without
    /// groups.*): honest absence, never a dead button.
    case unsupported
    /// No capability truth (probe not run, transport failure, or a source
    /// that cannot answer). Fail closed: do not flip the gate on it, and
    /// let any previously-known truth stand (last-known-good).
    case unknown
}

extension GroupsCreateCapability {
    /// Pure mapping from `groups.capabilities` truth (unit-testable without
    /// a transport).
    public init(capabilities: GroupsCapabilityTruth) {
        self = capabilities.driver && capabilities.methods.contains("groups.create")
            ? .supported
            : .unsupported
    }
}

/// The subset of `groups.capabilities` truth the create gate reads
/// (FleetNetworking's full `GroupsCapabilities` maps onto this app-side;
/// FleetCore stays transport-free).
public struct GroupsCapabilityTruth: Hashable, Sendable {
    public let driver: Bool
    public let methods: [String]

    public init(driver: Bool, methods: [String]) {
        self.driver = driver
        self.methods = methods
    }
}
