import Foundation

/// Globally unique identifier of a Hermes gateway (a fleet node / machine).
///
/// Canonical fleet identity is `GatewayID + ProfileSlug` — a display name is
/// never an identity. Two machines exposing similarly named profiles are two
/// distinct resources.
public struct GatewayID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// The ID is a safe routing key (M9): a single path-safe token with no
    /// `#` — otherwise the derived `Route.id` string could be ambiguous.
    public var isRoutingSafe: Bool {
        RoutingGuard.isValidRouteComponent(rawValue)
    }
}

extension GatewayID {
    /// Derive a stable, readable gateway ID from an http(s) endpoint
    /// (host + port), used when a registration does not supply an explicit ID
    /// (spec §12: a gateway always has an ID). Deterministic and collision
    /// free for distinct endpoints.
    public init(endpoint: URL) {
        let host = endpoint.host?.lowercased() ?? "unknown"
        if let port = endpoint.port {
            self.init(rawValue: "\(host):\(port)")
        } else {
            self.init(rawValue: host)
        }
    }
}
