/// A fleet gateway (Hermes node) as known to the client.
///
/// M0 ships the value shape only; discovery, connection state, and caching are
/// later milestones.
public struct FleetGateway: Identifiable, Hashable, Sendable {
    public let id: GatewayID
    public var displayName: String

    public init(id: GatewayID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
