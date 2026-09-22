import Foundation

/// The canonical identity used by local conversation organization.
///
/// Individual conversations are always scoped by their exact route and
/// session id. Group ids are already authoritative at the group-protocol
/// boundary, so the canonical group id deliberately does not include a
/// display name or an advertising gateway. That keeps one fleet-wide room
/// from becoming multiple pins when more than one gateway advertises it.
public enum FleetConversationIdentity: Hashable, Codable, Sendable, Identifiable {
    case individual(route: Route, sessionID: String)
    case group(canonicalID: String)

    public var id: String {
        switch self {
        case .individual(let route, let sessionID):
            return "individual:\(route.id)/\(sessionID)"
        case .group(let canonicalID):
            return "group:\(canonicalID)"
        }
    }

    public var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// A locally pinned conversation and the last safe presentation metadata
/// known for it. Metadata is retained so an offline gateway still has a
/// stable row; identity remains the only value used for routing.
public struct FleetConversationPin: Hashable, Codable, Sendable, Identifiable {
    public let identity: FleetConversationIdentity
    public var title: String
    public var preview: String
    /// The authoritative host for a hosted group, when the group protocol has
    /// supplied one. It is provenance, never a guessed fallback route.
    public var authoritativeGatewayID: GatewayID?
    /// A stable presentation key for a future group avatar or a bot avatar.
    /// The current UI uses the existing BotAvatar for individual chats.
    public var avatarKey: String?
    public let pinnedAt: Date

    public var id: String { identity.id }

    public init(
        identity: FleetConversationIdentity,
        title: String,
        preview: String = "",
        authoritativeGatewayID: GatewayID? = nil,
        avatarKey: String? = nil,
        pinnedAt: Date = Date()
    ) {
        self.identity = identity
        self.title = title
        self.preview = preview
        self.authoritativeGatewayID = authoritativeGatewayID
        self.avatarKey = avatarKey
        self.pinnedAt = pinnedAt
    }
}

/// Local-only persistence for conversation organization. There is no server
/// pinning contract in FleetCore, so this seam intentionally contains no RPC
/// or gateway transport dependency.
public protocol ConversationPinStoring: Sendable {
    func loadPins() async throws -> [FleetConversationPin]
    func savePins(_ pins: [FleetConversationPin]) async throws
}

/// UserDefaults-backed local pin store. The actor makes the persistence
/// boundary safe to call from the main-actor app environment and from a
/// relaunch without adding a competing conversation database.
public actor UserDefaultsConversationPinStore: ConversationPinStoring {
    public static let storageKey = "fleet.conversation.pins.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Constructs the store without sending a `UserDefaults` reference across
    /// an actor boundary. This is also convenient for isolated test suites.
    ///
    /// Fails (nil) when the named suite cannot be created rather than silently
    /// writing into the shared standard defaults: the suite exists to keep
    /// isolated/profile-scoped pins apart, so a silent `.standard` fallback
    /// would both leak pins across suites (the very thing `resetForUITests`
    /// exists to prevent) and hide the misconfiguration.
    public init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    public func loadPins() async throws -> [FleetConversationPin] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return try JSONDecoder().decode([FleetConversationPin].self, from: data)
    }

    public func savePins(_ pins: [FleetConversationPin]) async throws {
        let data = try JSONEncoder().encode(pins)
        defaults.set(data, forKey: Self.storageKey)
    }

    /// UI-test hygiene (HERMES_FLEET_NAV_RESET): pinned rows must not leak
    /// across suite runs on a shared simulator (same contract as the chats
    /// archive store). Tests launch with the reset flag; production never
    /// calls this — pins persist across launches by design.
    public static func resetForUITests() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// Small deterministic test double for conversation pin persistence.
public actor InMemoryConversationPinStore: ConversationPinStoring {
    private var pins: [FleetConversationPin]

    public init(pins: [FleetConversationPin] = []) {
        self.pins = pins
    }

    public func loadPins() async throws -> [FleetConversationPin] { pins }

    public func savePins(_ pins: [FleetConversationPin]) async throws {
        self.pins = pins
    }
}
