import Foundation
import FleetCore

/// Concrete `RosterProviding` that fetches the profile/bot roster and sessions
/// from a Hermes gateway over the WebSocket JSON-RPC transport.
///
/// M2 scope (synthesis §20 Phase 2): `profiles.list` and `session.list` only —
/// no conversation RPCs, no replay, no privileged operations. This type lives
/// in FleetNetworking (it needs the transport); FleetUI depends on the
/// `RosterProviding` protocol from FleetCore, never on this type.
public struct GatewayRosterClient: RosterProviding {
    /// The gateway this client is bound to. Every descriptor it returns is
    /// stamped with this identity, so roster aggregation preserves provenance.
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: RosterProviding

    public func fetchProfiles() async throws -> [ProfileDescriptor] {
        guard case .connected = transport.state else { throw RosterError.notConnected }
        let result = try await transport.request(method: "profiles.list", params: .object([:]))
        return try Self.decodeProfiles(result)
    }

    public func fetchSessions(for route: Route, limit: Int = 200) async throws -> [SessionSummary] {
        // M9 fail-closed guard: an unsafe route never reaches the transport.
        // This check precedes the connected-state check on purpose.
        guard route.isRoutingSafe else {
            throw RosterError.invalidRoute("route \(route.id) is not a safe routing key")
        }
        guard case .connected = transport.state else { throw RosterError.notConnected }
        let params: JSONValue = .object([
            "profile": .string(route.profileSlug.rawValue),
            "limit": .number(Double(limit)),
        ])
        let result = try await transport.request(method: "session.list", params: params)
        return try Self.decodeSessions(result)
    }

    // MARK: decoding (wire → domain)

    /// `profiles.list` → `{"profiles": [ {...} ]}` (methods_profiles.py).
    static func decodeProfiles(_ result: JSONValue) throws -> [ProfileDescriptor] {
        guard let profiles = result["profiles"]?.arrayValue else {
            throw RosterError.malformedPayload("profiles.list result missing 'profiles' array")
        }
        return profiles.compactMap { Self.decodeProfile($0) }
    }

    static func decodeProfile(_ json: JSONValue) -> ProfileDescriptor? {
        guard let object = json.objectValue else { return nil }
        guard let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        return ProfileDescriptor(
            name: name,
            path: object["path"]?.stringValue ?? "",
            isDefault: object["is_default"]?.boolValue ?? false,
            model: object["model"]?.stringValue,
            provider: object["provider"]?.stringValue,
            profileDescription: object["description"]?.stringValue,
            displayName: object["display_name"]?.stringValue,
            skillCount: object["skill_count"]?.numberValue.map(Int.init) ?? 0,
            hasAvatar: object["has_avatar"]?.boolValue ?? false,
            lastSession: object["last_session"].flatMap(Self.decodeSession),
            gatewayRunning: object["gateway_running"]?.boolValue ?? false
        )
    }

    /// `session.list` → `{"sessions": [ {...} ]}` (methods_session.py).
    static func decodeSessions(_ result: JSONValue) throws -> [SessionSummary] {
        guard let sessions = result["sessions"]?.arrayValue else {
            throw RosterError.malformedPayload("session.list result missing 'sessions' array")
        }
        return sessions.compactMap(Self.decodeSession)
    }

    static func decodeSession(_ json: JSONValue) -> SessionSummary? {
        guard let object = json.objectValue else { return nil }
        guard let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
        return SessionSummary(
            id: id,
            title: object["title"]?.stringValue ?? "",
            preview: object["preview"]?.stringValue ?? "",
            startedAt: object["started_at"]?.numberValue ?? 0,
            lastActive: object["last_active"]?.numberValue ?? 0,
            messageCount: object["message_count"]?.numberValue.map(Int.init) ?? 0,
            source: object["source"]?.stringValue
        )
    }
}
