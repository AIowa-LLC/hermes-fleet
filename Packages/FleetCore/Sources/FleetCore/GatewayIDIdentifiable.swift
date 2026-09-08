import Foundation

/// FOS-2: GatewayID as Identifiable via its raw value (stable, non-secret).
extension GatewayID: Identifiable {
    public var id: String { rawValue }
}
