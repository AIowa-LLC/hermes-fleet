import Foundation

/// Pure validation of routing keys and session keys (M9 Routing Collision
/// Hardening).
///
/// Two kinds of string enter the routing/RPC path, and both must be kept
/// collision-free and traversal-safe (synthesis §14 threat model:
/// "path/session-key traversal"; spec §5.6 "fail closed on ambiguity"):
///
/// - **Route components** (`GatewayID` / `ProfileSlug`): a bare, unvalidated
///   component would let a gateway or slug smuggle path separators, traversal
///   segments, or the Route.id separator `#` into the fleet identity. Two
///   routes like `a#b / c` and `a / b#c` would collapse to the same
///   `Route.id` string `a#b#c` — an id collision the resolver could never
///   distinguish.
/// - **Session keys** (`session_id` on resume/submit/interrupt/history/status):
///   an unvalidated key with `/` or `..` is a path-traversal vector into the
///   gateway's session namespace.
///
/// `isValidRouteComponent` rejects anything that is not a single path-safe
/// token; `isValidSessionKey` rejects anything that is not an opaque session
/// identifier. Both fail CLOSED: an invalid key never reaches the transport
/// or the roster — callers surface a typed error instead of guessing.
public enum RoutingGuard {
    /// Validate one route component (gateway ID or profile slug).
    ///
    /// Rejects: empty, `.`, `..`, any `..` segment, `/`, `\`, whitespace,
    /// control characters, and `#` (the `Route.id` separator). Allows the
    /// characters that actually appear in fleet identities: letters, digits,
    /// `-`, `_`, `.` (within a token, e.g. `192.168.50.58`), `:` (host:port
    /// derived IDs).
    public static func isValidRouteComponent(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw != ".", raw != ".." else { return false }
        guard !raw.contains("..") else { return false }
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", "\\", "#":
                return false
            case let s where CharacterSet.whitespacesAndNewlines.contains(s):
                return false
            case let s where s.value < 0x20 || s.value == 0x7F:
                // Control characters (C0 + DEL).
                return false
            default:
                continue
            }
        }
        return true
    }

    /// Validate a session key (`session_id`) before it is placed into an RPC
    /// parameter. Session ids are opaque identifiers; reject path separators,
    /// traversal segments, whitespace, and control characters.
    public static func isValidSessionKey(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw != ".", raw != ".." else { return false }
        guard !raw.contains("..") else { return false }
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", "\\":
                return false
            case let s where CharacterSet.whitespacesAndNewlines.contains(s):
                return false
            case let s where s.value < 0x20 || s.value == 0x7F:
                return false
            default:
                continue
            }
        }
        return true
    }
}
