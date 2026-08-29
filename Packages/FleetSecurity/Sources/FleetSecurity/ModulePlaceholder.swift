import FleetCore

/// M0 establishes the `FleetSecurity` module boundary ONLY.
///
/// This module will own Keychain-backed credential storage, the authorization
/// classifier, and secret redaction. NO auth flow or Keychain code is
/// implemented yet — gated behind a later milestone. Tokens live only in
/// Keychain, never in source, logs, or app storage.
public enum FleetSecurityPlaceholder {
    public static func label(for authorizationClass: AuthorizationClass) -> String {
        authorizationClass.rawValue
    }
}
