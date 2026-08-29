/// Hermes profile slug (e.g. "default", "researcher", "apple-dev").
///
/// A profile slug alone is NOT a unique resource — the same slug exists on
/// many gateways. Combine with `GatewayID` for canonical identity, and fail
/// closed rather than guessing when ownership is ambiguous.
public struct ProfileSlug: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// The slug is a safe routing key (M9): a single path-safe token with no
    /// `#` — otherwise the derived `Route.id` string could be ambiguous and
    /// the slug could smuggle path traversal into `session.list`/`session.create`.
    public var isRoutingSafe: Bool {
        RoutingGuard.isValidRouteComponent(rawValue)
    }
}
