import FleetCore

/// M0 established the `FleetSecurity` module boundary.
///
/// The module now owns Keychain-backed credential/token storage
/// (`KeychainCredentialStore`, `KeychainTokenStore`, `KeychainSession`,
/// `CredentialEncoding`) with atomic upsert, plus in-memory stores for tests.
/// The authorization classifier (`AuthorizationClass`) and secret redaction
/// (`Redaction`) live in `FleetCore`, not here. This placeholder remains only
/// as the M0 module-boundary seam exercised by `ModuleBoundaryTests`. Tokens
/// live only in Keychain, never in source, logs, or app storage.
public enum FleetSecurityPlaceholder {
    public static func label(for authorizationClass: AuthorizationClass) -> String {
        authorizationClass.rawValue
    }
}
