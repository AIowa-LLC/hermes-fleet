import Foundation

/// A partial edit to an existing gateway (spec §15.2 "edit display
/// information"). `nil` fields are left unchanged; `authConfiguration` may be
/// edited directly, while the credential itself flows through
/// `CredentialStoring` (never through this value).
public struct GatewayEdit: Sendable, Equatable {
    public var displayName: String?
    public var endpoint: URL?
    public var authConfiguration: GatewayAuthConfiguration?

    public init(
        displayName: String? = nil,
        endpoint: URL? = nil,
        authConfiguration: GatewayAuthConfiguration? = nil
    ) {
        self.displayName = displayName
        self.endpoint = endpoint
        self.authConfiguration = authConfiguration
    }

    /// Apply the non-nil fields onto a gateway, returning the updated value.
    public func applied(to gateway: FleetGateway) -> FleetGateway {
        var updated = gateway
        if let displayName {
            updated.displayName = displayName
        }
        if let endpoint {
            updated.endpoint = endpoint
        }
        if let authConfiguration {
            updated.authConfiguration = authConfiguration
        }
        return updated
    }
}
