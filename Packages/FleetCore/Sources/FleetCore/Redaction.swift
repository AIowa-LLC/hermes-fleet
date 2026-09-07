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
    ///
    /// P1-6: user-info (`user:pass@host`) is also stripped — credential
    /// material embedded in a URL must never reach logs or UI, regardless of
    /// the query keys.
    public static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return placeholder
        }
        // Strip any user-info half (user:pass@) before printing.
        components.user = nil
        components.password = nil
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

    /// MARK: R9-T1 — approval command preview (second-pass redaction).
    ///
    /// The gateway redacts credentials from `approval.request.command`
    /// server-side (#48456, `_redact_approval_command` in gateway/run.py),
    /// but the client never trusts that blindly: this pass masks common
    /// credential-shaped substrings (`Bearer <token>`, `token=`, `password=`,
    /// long hex/base64 runs after a credential keyword) with `[REDACTED]`
    /// before the preview is rendered in the approval banner. Structure
    /// survives — the user must still recognize the command to decide.
    public static func commandPreview(_ command: String) -> String {
        guard !command.isEmpty else { return command }
        var masked = command
        for pattern in Self.previewSecretPatterns {
            masked = pattern.stringByReplacingMatches(
                in: masked,
                range: NSRange(masked.startIndex..., in: masked),
                withTemplate: "$1[REDACTED]"
            )
        }
        return masked
    }

    /// Credential-shaped patterns for `commandPreview`. Each keeps a leading
    /// separator/quote as capture group 1 so the masking stays readable.
    private static let previewSecretPatterns: [NSRegularExpression] = {
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,          // Authorization: Bearer xxx
            #"(?i)((?:api[_-]?key|token|password|passwd|secret)[\"']?\s*[:=]\s*[\"']?)[^\s\"']{6,}"#,
            #"(?i)((?:token|apikey|api_key|pass|password)=)[^&\s]{6,}"#,  // ?token=xxx / --pass=xxx
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}
