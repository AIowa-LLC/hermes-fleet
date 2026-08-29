import FleetCore

/// M0 establishes the `FleetPersistence` module boundary ONLY.
///
/// This module will own the non-secret cache (SwiftData) of gateway/task state
/// with a migration/versioning story. NO persistence schema is implemented yet —
/// gated behind a later milestone. Secrets never belong here; tokens live only
/// in Keychain.
public enum FleetPersistencePlaceholder {
    public static func displayName(of gateway: FleetGateway) -> String {
        gateway.displayName
    }
}
