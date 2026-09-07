import Foundation

/// The `gateway.ready` handshake metadata adopted after a successful connect.
///
/// Pure domain value (FleetCore) so the UI can render the adopted capabilities
/// and replay epoch without importing the transport module. The transport
/// layer maps its wire payload onto this type in `SingleGatewayConnection`.
///
/// Wire contract (verified in `tui_gateway/ws.py:369-389`):
/// `gateway.ready` → `{skin, change_events, heartbeat, replay_epoch}`.
public struct GatewayReadyAdoption: Hashable, Sendable {
    /// Replay epoch from the gateway (drives rehydration, spec §9 / §31
    /// Reconnect "gateway restart/epoch change triggers safe rehydration").
    public let replayEpoch: String?
    /// `heartbeat: true` → the gateway expects the client to ping.
    public let heartbeatEnabled: Bool
    /// `change_events: true` → the gateway streams change notifications.
    public let changeEventsEnabled: Bool

    public init(replayEpoch: String?, heartbeatEnabled: Bool, changeEventsEnabled: Bool) {
        self.replayEpoch = replayEpoch
        self.heartbeatEnabled = heartbeatEnabled
        self.changeEventsEnabled = changeEventsEnabled
    }

    /// Capability flags advertised by the gateway (spec §12 "capabilities").
    public var capabilities: Set<String> {
        var result = Set<String>()
        if heartbeatEnabled { result.insert("heartbeat") }
        if changeEventsEnabled { result.insert("change_events") }
        return result
    }
}
