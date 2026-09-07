import Foundation

/// In-memory registry of registered gateways, keyed by `GatewayID`.
///
/// M2 (synthesis §20 Phase 2): the gateway half of the fleet model. Identity is
/// `GatewayID`; display name is presentation-only. Registration is explicit —
/// a gateway must be registered before any route resolves against it, and
/// lookups fail closed (return `nil`) when the gateway is absent.
public struct GatewayRegistry: Sendable, Equatable {
    public private(set) var gateways: [GatewayID: FleetGateway]

    public init(gateways: [FleetGateway] = []) {
        self.gateways = Dictionary(uniqueKeysWithValues: gateways.map { ($0.id, $0) })
    }

    // MARK: mutation

    /// Register a new gateway, or replace the existing entry with the same ID.
    public mutating func register(_ gateway: FleetGateway) {
        gateways[gateway.id] = gateway
    }

    /// Update a field on an existing gateway; no-op when the gateway is absent.
    public mutating func update(_ id: GatewayID, transform: (inout FleetGateway) -> Void) {
        guard var gateway = gateways[id] else { return }
        transform(&gateway)
        gateways[id] = gateway
    }

    /// Update connection state only (the common transport-driven mutation).
    public mutating func updateConnectionState(_ id: GatewayID, _ state: TransportState) {
        update(id) { $0.connectionState = state }
    }

    /// Remove a gateway (and with it every route that referenced it).
    public mutating func remove(_ id: GatewayID) {
        gateways.removeValue(forKey: id)
    }

    // MARK: lookup (fail closed)

    /// The registered gateway for an ID, or `nil`.
    public func gateway(for id: GatewayID) -> FleetGateway? {
        gateways[id]
    }

    /// All registered gateways in stable ID order.
    public var allGateways: [FleetGateway] {
        gateways.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
