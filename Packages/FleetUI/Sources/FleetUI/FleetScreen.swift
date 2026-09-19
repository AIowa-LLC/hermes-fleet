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
    /// Card D: the device-local Artifacts destination (observed generated
    /// media with source conversation + gateway). Lives on the Fleet stack;
    /// reached from the navigation drawer.
    case artifacts

    public var owner: FleetTab {
        switch self {
        case .roster, .bots, .botDetail, .botRoutines, .gatewayGroups: .bots
        case .room: .groups
        case .conversation(_, _, let canonical): canonical ? .bots : .chats
        case .activity: .fleet
        // Build 41: Kanban owns the Kanban experience (from Gateway Detail
        // too — routing into the tab with the gateway context selected).
        case .kanban, .gatewayKanban: .kanban
        // Build 43: Gateways is no longer a tab — every gateway-management
        // and gateway-resource surface is owned by Fleet and PUSHED on the
        // Fleet stack (the dashboard's Gateways section is the entry).
        case .gateways, .gatewayDetail, .gatewayConnection, .gatewayHealth,
             .health, .cron, .skills, .memoryGraph, .projects, .artifacts:
            .fleet
        }
    }

    /// ADR-0010: room destinations own to the Groups tab.
    public var isRoom: Bool {
        if case .room = self { return true }
        return false
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
    /// Build 41: Bots is the normal launch tab.
    public var selection: FleetTab = .bots
    public var paths: [FleetTab: [FleetScreen]] = [:]
    public init() {}

    public mutating func open(_ screen: FleetScreen) {
        selection = screen.owner
        // `.roster` is the Bots tab's own ROOT (pop to it). `.gateways` is
        // NOT Fleet's root — the dashboard is — so it must PUSH on the
        // Fleet stack (Build 43: Gateways lives under Fleet).
        if screen == .roster {
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

    // Build 43 legacy restore: FleetTab.gateways was REMOVED from the enum.
    // A persisted state saved by Build ≤42 can carry selection="gateways"
    // and/or a "gateways" path entry. Decoding must not fail (a failure would
    // discard the user's ENTIRE navigation preference set via `restore`'s
    // Self() fallback) — the legacy tab maps to Fleet and its stack is
    // restored ON the Fleet stack, preserving every unrelated tab's path.
    //
    // Wire format note: Swift's synthesized Codable encodes
    // [FleetTab: [FleetScreen]] as an UNKEYED array of alternating
    // key/value pairs (dictionary keys that are not String/Int). The custom
    // decoder below decodes exactly that shape, remapping the retired
    // "gateways" key onto Fleet. Encoding stays synthesized (unchanged), so
    // current round-trips remain byte-stable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let rawSelection = try container.decodeIfPresent(String.self, forKey: .selection)
        if let rawSelection {
            selection = FleetTab(rawValue: rawSelection)
                ?? Self.legacyRestoredSelection(rawSelection)
                ?? .bots
        } else {
            selection = .bots
        }
        var merged: [FleetTab: [FleetScreen]] = [:]
        if container.contains(.paths) {
            var rawPaths = try container.nestedUnkeyedContainer(forKey: .paths)
            while !rawPaths.isAtEnd {
                let key = try rawPaths.decode(String.self)
                let screens = try rawPaths.decode([FleetScreen].self)
                if let tab = FleetTab(rawValue: key) {
                    merged[tab, default: []].append(contentsOf: screens)
                } else if key == Self.legacyGatewaysRawValue, !screens.isEmpty {
                    // The retired Gateways tab's stack is appended to
                    // Fleet's (Fleet owns those destinations now). When both
                    // existed, Fleet's own path stays first; the gateway
                    // screens restore deeper, so no saved destination is
                    // lost.
                    merged[.fleet, default: []].append(contentsOf: screens)
                }
            }
        }
        // ADR-0010: `.room` screens own to the Groups tab now. Persisted
        // Chats paths from pre-Groups installs carried room destinations —
        // migrate them onto the Groups path (order preserved, other tabs
        // untouched) so a restored stack never pushes a room on the Chats
        // stack (and `open(.room)`'s same-screen dedupe stays coherent).
        if let chatsPath = merged[.chats], chatsPath.contains(where: \.isRoom) {
            let retained = chatsPath.filter { !$0.isRoom }
            let migrated = chatsPath.filter { $0.isRoom }
            merged[.chats] = retained
            merged[.groups, default: []].insert(contentsOf: migrated, at: 0)
        }
        paths = merged
    }

    /// Raw value of the retired Build ≤42 Gateways tab case.
    private static let legacyGatewaysRawValue = "gateways"

    /// Legacy persisted selections that no longer have a live case map to
    /// their owning surface; unknown values fall back to the launch tab.
    private static func legacyRestoredSelection(_ raw: String) -> FleetTab? {
        switch raw.lowercased() {
        case legacyGatewaysRawValue: return .fleet
        default: return nil
        }
    }

    public static func legacyTab(_ name: String) -> FleetTab? {
        switch name.lowercased() {
        case "home", "command", "fleet": .fleet
        case "chats": .chats
        case "groups": .groups
        case "bots", "roster": .bots
        case "kanban", "board": .kanban
        case "settings": .settings
        // Build 43: the Gateways tab is retired; every legacy gateway
        // destination (control / gateways / workspace / projects) lands on
        // Fleet, which now owns the gateway-management experience.
        case "control", "gateways", "workspace", "projects": .fleet
        default: nil
        }
    }
}
