import Foundation

/// A per-gateway roster session: connectivity + roster RPCs over ONE transport.
///
/// M8 composes the M3 connectivity seam (`GatewayConnectivityProviding`) with
/// the M2 roster seam (`RosterProviding`) into the unit the aggregation
/// service drives per registered gateway. Combining them means one object per
/// gateway owns the socket AND the `profiles.list` / `session.list` calls on
/// that same socket — so a refresh connects once, fetches the roster, and
/// tears the session down (ADR: probe teardown on every path).
///
/// `SingleGatewayConnection` (FleetNetworking) conforms by delegating the
/// roster RPCs to a `GatewayRosterClient` bound to its own transport.
public protocol GatewayRosterSession: GatewayConnectivityProviding, RosterProviding {}
