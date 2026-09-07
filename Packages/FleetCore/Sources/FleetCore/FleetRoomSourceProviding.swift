import Foundation

/// FleetUI-facing seam for a gateway's room source (both provenances,
/// unioned). The concrete `GatewayRoomSource` lives app-side; FleetUI
/// depends only on this abstraction (module boundary).
public protocol FleetRoomSourceProviding: Sendable {
    /// All live rooms visible through this gateway (hosted + desktop legacy,
    /// identities never merged). Best-effort per provenance: a failing
    /// source contributes nothing rather than failing the whole call.
    func rooms() async -> [FleetRoom]
}
