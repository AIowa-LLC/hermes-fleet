import Foundation

/// Normalization / validation of a user-supplied gateway endpoint as an
/// ORIGIN (P1-6).
///
/// Endpoint input is treated as an origin, not a full URL: user-info
/// (`user:pass@host`) is REJECTED and query/fragment are STRIPPED at the
/// registry boundary, so credential material embedded in a pasted URL can
/// never be persisted, displayed, or logged.
public enum GatewayEndpoint {
    /// Validate + normalize an endpoint to a clean origin URL.
    ///
    /// - Requires an `http` / `https` scheme.
    /// - Rejects any user-info (`url.user`/`url.password` non-nil) —
    ///   credentials belong in Keychain, never in the endpoint.
    /// - Strips query and fragment, preserving scheme/host/port/path.
    ///
    /// Throws `GatewayRegistryError.invalidEndpoint` when the input is not a
    /// usable origin.
    /// Join an API path onto a gateway endpoint's own path prefix.
    ///
    /// A path-scoped gateway (`https://host/gw`) must keep its prefix: setting
    /// `URLComponents.path` to an absolute API path would silently retarget the
    /// request (and its credential) at whatever service owns the origin root.
    public static func path(joining apiPath: String, onto base: URL) -> String {
        let prefix = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        let suffix = apiPath.hasPrefix("/") ? apiPath : "/" + apiPath
        return prefix + suffix
    }

    public static func normalizedOrigin(from url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw GatewayRegistryError.invalidEndpoint
        }
        guard url.user == nil, url.password == nil else {
            // user-info (user:pass@host) is never an acceptable origin —
            // credential material must not reach the registry, logs, or UI.
            throw GatewayRegistryError.invalidEndpoint
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        guard let origin = components?.url else {
            throw GatewayRegistryError.invalidEndpoint
        }
        return origin
    }
}
