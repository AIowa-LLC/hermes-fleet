import Foundation

/// #188 — paged, newest-first session history for chats whose lineage is too
/// large for `session.history` (one unbounded WebSocket frame).
///
/// Wire contract (Hermes 0.22.1, `hermes_cli/web_routers/sessions.py`):
/// `GET {dashboard}/api/sessions/{id}/messages?order=latest&limit=N&offset=K`.
/// `offset` skips the K NEWEST rows; rows come back oldest→newest. The
/// implementation lives in FleetNetworking; FleetUI sees only this seam.
public protocol SessionHistoryPaging: Sendable {
    /// Fetch one page of the newest-first window.
    /// - Parameters:
    ///   - sessionID: the session's durable id (route-validated by the implementation).
    ///   - profile: the owning gateway profile, when the gateway scopes by profile.
    ///   - offset: how many NEWEST raw rows to skip.
    ///   - limit: page size; the implementation clamps it to the server window.
    func fetchLatestPage(sessionID: String, profile: String?, offset: Int, limit: Int) async throws -> SessionHistoryPage
}

/// One page of paged history.
public struct SessionHistoryPage: Sendable, Equatable {
    /// Decoded, renderable messages in chronological (oldest→newest) order.
    /// Hidden and empty rows are dropped here, so `messages.count` may be less
    /// than `returned`.
    public let messages: [SessionMessage]
    /// The offset that was requested.
    public let offset: Int
    /// The limit that was requested (after client clamping).
    public let limit: Int
    /// RAW row count the server returned, BEFORE any client filtering. Paging
    /// advances by this value, never by `messages.count`.
    public let returned: Int

    public init(messages: [SessionMessage], offset: Int, limit: Int, returned: Int) {
        self.messages = messages
        self.offset = offset
        self.limit = limit
        self.returned = returned
    }

    /// Older rows exist iff the server filled the page.
    public var hasOlder: Bool { returned >= limit }
}

/// Failures of the paged history path. Every case carries non-secret text.
public enum SessionHistoryPagingError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway does not expose the paged route (older gateway: 404 with no
    /// session-specific detail, 405, 501).
    case unsupported(String)
    /// The gateway does not know the session.
    case sessionNotFound(String)
    /// The dashboard rejected the credential (401/403).
    case unauthorized
    /// Network / TLS / cancellation-free transport failure.
    case transport(String)
    /// The body could not be decoded into the page contract.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "paged history unsupported: \(s)"
        case .sessionNotFound(let s): return "session not found: \(s)"
        case .unauthorized: return "dashboard credential rejected"
        case .transport(let s): return "paged history transport failed: \(s)"
        case .malformed(let s): return "malformed paged history: \(s)"
        }
    }
}

/// Sessions whose concrete type carries a paged-history seam (#188). The UI
/// resolves it with ONE cast at build time, the same discipline as
/// `ApprovalsCapable`. `nil` means this session cannot page.
public protocol SessionHistoryPagingCapable: ConversationSessionProviding {
    var historyPager: (any SessionHistoryPaging)? { get }
}
