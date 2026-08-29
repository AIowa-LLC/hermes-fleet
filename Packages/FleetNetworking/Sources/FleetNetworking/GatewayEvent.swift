import Foundation

/// Typed view of the gateway's server→client event frames
/// (`{"jsonrpc":"2.0","method":"event","params":{"type":...,"payload":...}}`).
///
/// M1 implements only the events the transport needs for its own lifecycle
/// (`gateway.ready`, `error`); the conversation/streaming vocabulary
/// (`message.*`, `tool.*`, `status.update`, …) is a later milestone (P3).
public struct GatewayEvent: Sendable, Hashable {
    public enum EventType: String, Sendable, Hashable {
        case gatewayReady = "gateway.ready"
        case error = "error"

        /// Unknown event types are preserved for forward compatibility and
        /// surfaced raw rather than dropped, so M2+ can decode them.
        case unknown
    }

    public let type: EventType
    public let rawType: String
    public let sessionID: String?
    public let seq: Int?
    public let payload: JSONValue?

    public init(type: EventType, rawType: String, sessionID: String? = nil,
                seq: Int? = nil, payload: JSONValue? = nil) {
        self.type = type
        self.rawType = rawType
        self.sessionID = sessionID
        self.seq = seq
        self.payload = payload
    }

    /// Decode an inbound `method:"event"` notification.
    public init?(event: JSONRPCEvent) {
        guard let params = event.params?.objectValue else { return nil }
        let raw = params["type"]?.stringValue ?? ""
        self.rawType = raw
        self.type = EventType(rawValue: raw) ?? .unknown
        self.sessionID = params["session_id"]?.stringValue
        self.seq = params["seq"]?.numberValue.map(Int.init)
        self.payload = params["payload"]
    }

    /// The `gateway.ready` payload: skin, change_events, heartbeat flag and
    /// replay_epoch. Verified against `tui_gateway/ws.py:369-389`.
    public struct ReadyPayload: Sendable, Hashable {
        public let skin: JSONValue?
        public let changeEvents: Bool
        public let heartbeat: Bool
        public let replayEpoch: String?

        public init(skin: JSONValue?, changeEvents: Bool, heartbeat: Bool, replayEpoch: String?) {
            self.skin = skin
            self.changeEvents = changeEvents
            self.heartbeat = heartbeat
            self.replayEpoch = replayEpoch
        }

        public init(payload: JSONValue?) {
            guard let o = payload?.objectValue else {
                self.init(skin: nil, changeEvents: false, heartbeat: false, replayEpoch: nil)
                return
            }
            self.init(
                skin: o["skin"],
                changeEvents: o["change_events"]?.boolValue ?? false,
                heartbeat: o["heartbeat"]?.boolValue ?? false,
                replayEpoch: o["replay_epoch"]?.stringValue
            )
        }
    }

    /// `gateway.ready` view (the handshake the client waits for on connect).
    public var ready: ReadyPayload? {
        guard type == .gatewayReady else { return nil }
        return ReadyPayload(payload: payload)
    }
}
