import Foundation

/// The `session.list` READ seam for a bot detail screen (spec §31 Sessions,
/// §5.4 observation-does-not-own).
///
/// Mirrors `RosterProviding.fetchSessions(for:limit:)` but as a standalone,
/// route-scoped seam the app runtime can inject at the composition root:
/// SwiftUI depends on this protocol — never on the concrete service in
/// FleetNetworking (M0 hard guard). A concrete implementation builds a
/// per-gateway roster session over the transport, connects, calls
/// `session.list`, and tears the session down on every exit path.
///
/// Observation only: this seam deliberately exposes NO mutating operation
/// (no create, resume, interrupt, close) — a screen that lists sessions
/// structurally cannot seize or mutate the session's transport (spec §5.4;
/// spec §36 session-safety "read-only screens do not accidentally issue
/// mutating calls").
public protocol SessionListProviding: Sendable {
    /// Fetch the sessions owned by an exact `(gateway, profile)` route via
    /// the read-only `session.list` method.
    /// - Parameters:
    ///   - route: the exact routing identity; the profile slug scopes the call.
    ///   - limit: max sessions to return (gateway default 200).
    /// - Returns: session rows in gateway order; empty on a healthy gateway
    ///   with no sessions.
    /// - Throws: `RosterError` (notConnected / malformedPayload / rpcFailed /
    ///   invalidRoute) — never a thrown crash, always a classified failure.
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary]
}
