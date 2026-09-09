import Foundation
import FleetCore

/// Durable, source-qualified navigation. Payloads contain identity, never credentials
/// or mutable room authority snapshots. Missing targets remain unavailable.
public enum FleetScreen: Hashable, Sendable, Codable {
    case bots(GatewayID)
    case roster
    case botDetail(Route)
    case botRoutines(Route)
    case room(FleetRoomID)
    case conversation(Route, sessionID: String?, canonical: Bool = false)
    case health
    case gateways
    case gatewayDetail(GatewayID)
    case gatewayConnection(GatewayID)
    case gatewayGroups(GatewayID)
    case gatewayHealth(GatewayID)
    case activity
    /// Legacy unscoped entry: requires an explicit gateway choice.
    case kanban
    case gatewayKanban(GatewayID, board: String? = nil)
    case cron(GatewayID, profile: ProfileSlug? = nil)
    case skills(GatewayID, profile: ProfileSlug? = nil)
    case memoryGraph(GatewayID, profile: ProfileSlug? = nil)
    case projects(GatewayID, profile: ProfileSlug? = nil, focusPath: String? = nil)

    public var owner: FleetTab {
        switch self {
        case .roster, .bots, .botDetail, .botRoutines, .room, .gatewayGroups: .bots
        case .conversation(_, _, let canonical): canonical ? .bots : .chats
        case .activity: .fleet
        default: .gateways
        }
    }

    public var gatewayID: GatewayID? {
        switch self {
        case .bots(let id), .gatewayDetail(let id), .gatewayConnection(let id), .gatewayGroups(let id), .gatewayHealth(let id), .gatewayKanban(let id, _),
             .cron(let id, _), .skills(let id, _), .memoryGraph(let id, _), .projects(let id, _, _): id
        case .botDetail(let route), .botRoutines(let route), .conversation(let route, _, _): route.gatewayID
        case .room(let id): id.gatewayID
        default: nil
        }
    }

    /// Focused-path intent for Projects routes (transcript file references).
    public var focusPath: String? {
        if case .projects(_, _, let path) = self { return path }
        return nil
    }
}

/// One stack per domain. Opening an existing exact object focuses it and removes
/// only destinations above it; another domain's source stack is untouched.
public struct FleetNavigationState: Codable, Equatable, Sendable {
    /// Identifier for the UserDefaults-backed navigation-state store — not a secret.
    public static let storageKey = "fleet.navigation.v1" // gitleaks:allow
    public private(set) var version = 1
    public var selection: FleetTab = .fleet
    public var paths: [FleetTab: [FleetScreen]] = [:]
    public init() {}

    public mutating func open(_ screen: FleetScreen) {
        selection = screen.owner
        if screen == .roster || screen == .gateways {
            paths[selection] = []
        } else if let index = paths[selection]?.firstIndex(of: screen) {
            paths[selection] = Array(paths[selection]!.prefix(through: index))
        } else {
            paths[selection, default: []].append(screen)
        }
    }

    public static func restore(_ data: Data?) -> Self {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.version == 1 else { return Self() }
        return decoded
    }

    public static func legacyTab(_ name: String) -> FleetTab? {
        switch name.lowercased() {
        case "home", "command", "fleet": .fleet
        case "chats": .chats
        case "bots", "roster": .bots
        case "control", "gateways", "workspace", "projects", "kanban": .gateways
        default: nil
        }
    }
}
