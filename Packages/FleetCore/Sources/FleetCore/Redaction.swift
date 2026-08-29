import Foundation

/// Redaction helpers (spec §29 Logging: "Logs must never contain … WebSocket
/// tickets, API credentials … Network error logs should redact credentials
/// and sensitive query parameters.").
///
/// These are pure string/URL transformations so the transport layer can log a
/// redacted description of a request/URL without ever echoing a secret value.
public enum Redaction {
    /// The literal placeholder substituted for a redacted secret.
    public static let placeholder = "[REDACTED]"

    /// Query-parameter names whose values are secrets and must never be
    /// logged: WS tickets (`ticket`), auth tokens (`token`, `access_token`,
    /// `session_token`, `refresh_token`, `api_key`, `apikey`, `key`),
    /// passwords, and the loopback `internal` marker.
    public static let sensitiveQueryKeys: Set<String> = [
        "ticket",
        "token",
        "access_token",
        "refresh_token",
        "session_token",
        "id_token",
        "api_key",
        "apikey",
        "key",
        "password",
        "passwd",
        "secret",
        "internal",
        "auth",
        "authorization",
    ]

    /// Redact the sensitive query parameters of a URL, returning a safe
    /// printable string. The scheme/host/path and non-secret query values are
    /// preserved (so a human can still tell WHICH gateway failed, per spec
    /// §30), while every sensitive value is replaced with `[REDACTED]`.
    public static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return placeholder
        }
        let items = components.queryItems?.map { item -> URLQueryItem in
            guard sensitiveQueryKeys.contains(item.name) else { return item }
            return URLQueryItem(name: item.name, value: placeholder)
        }
        components.queryItems = items
        return components.string ?? placeholder
    }

    /// Redact a single sensitive string value. Used when a secret would
    /// otherwise be interpolated into an error/log message.
    public static func redacted(_ value: String) -> String {
        placeholder
    }
}
