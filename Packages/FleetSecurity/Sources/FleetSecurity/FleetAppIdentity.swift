import Foundation

/// App-private namespaces derived from the actual host bundle, never a package
/// compiler flag (app compilation conditions do not propagate to packages).
/// Production namespaces remain stable so existing secrets/data open in place.
public enum FleetAppIdentity {
    public struct Identity: Equatable, Sendable {
        public let keychainNamespace: String
        public let conversationURLScheme: String
        public let cacheDirectoryName: String
        public let isDevelopment: Bool
    }

    public enum ConfigurationError: Error {
        case mismatchedDevelopmentIdentity
    }

    /// Injectable metadata makes identity tests hermetic. Non-app test hosts
    /// retain legacy production defaults; the explicit Dev bundle and marker
    /// must agree, so Dev cannot silently fall back to production services.
    public static func resolve(bundleIdentifier: String?, developmentMarker: Bool) throws -> Identity {
        let isDevelopmentBundle = bundleIdentifier == "com.aiowa.hermesfleet.dev"
        guard isDevelopmentBundle == developmentMarker else {
            throw ConfigurationError.mismatchedDevelopmentIdentity
        }
        return isDevelopmentBundle
            ? Identity(keychainNamespace: "com.aiowa.hermesfleet.dev",
                       conversationURLScheme: "hermes-fleet-dev",
                       cacheDirectoryName: "HermesFleetDevCache", isDevelopment: true)
            : Identity(keychainNamespace: "com.aiowa.hermesfleet",
                       conversationURLScheme: "hermes-fleet",
                       cacheDirectoryName: "HermesFleetCache", isDevelopment: false)
    }

    public static let current: Identity = {
        do {
            return try resolve(bundleIdentifier: Bundle.main.bundleIdentifier,
                               developmentMarker: Bundle.main.object(forInfoDictionaryKey: "FleetDevBuild") as? Bool == true)
        } catch {
            preconditionFailure("Fleet development bundle identity and marker disagree")
        }
    }()

    public static var keychainNamespace: String { current.keychainNamespace }
    public static var conversationURLScheme: String { current.conversationURLScheme }
    public static var cacheDirectoryName: String { current.cacheDirectoryName }
}
