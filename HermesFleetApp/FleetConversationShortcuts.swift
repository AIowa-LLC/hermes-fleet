import AppIntents
import FleetCore
import FleetUI
import Foundation

/// A Shortcuts-safe identity for one previously opened Fleet conversation.
/// Only the source-qualified route/session identity and minimal display labels
/// are exposed; credentials, endpoints, transcript text, and prompts never
/// enter App Intents metadata.
struct FleetConversationShortcutEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fleet Conversation")
    static let defaultQuery = FleetConversationShortcutQuery()

    let id: String
    let route: Route
    let sessionID: String
    let canonical: Bool
    /// Non-secret display labels carried from the continue index (the same
    /// minimum-needed row metadata the cached row renders). Without them every
    /// entry in the Shortcuts/Siri entity picker reads one constant title, so
    /// the user cannot tell which conversation they are choosing.
    var title: String = ""
    var subtitle: String = ""

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(
                stringLiteral: title.isEmpty ? "Fleet conversation" : title),
            subtitle: LocalizedStringResource(
                stringLiteral: subtitle.isEmpty
                    ? (canonical ? "Bot Chat" : "Saved conversation")
                    : subtitle)
        )
    }
}

struct FleetConversationShortcutQuery: EntityQuery {
    func entities(for identifiers: [FleetConversationShortcutEntity.ID]) async throws -> [FleetConversationShortcutEntity] {
        let wanted = Set(identifiers)
        return Self.load().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FleetConversationShortcutEntity] {
        Self.load()
    }

    private static func load() -> [FleetConversationShortcutEntity] {
        let store = FleetContinueIndexStore(url: FleetContinueIndexStore.defaultURL())
        return store.entries().compactMap { entry in
            guard entry.kind == .ordinaryConversation || entry.kind == .canonicalBotChat,
                  let profile = entry.routeProfile,
                  let sessionID = entry.sessionID,
                  let route = Route(
                    validating: GatewayID(rawValue: entry.gatewayIDRaw),
                    profileSlug: ProfileSlug(rawValue: profile)),
                  RoutingGuard.isValidSessionKey(sessionID) else { return nil }
            return FleetConversationShortcutEntity(
                id: entry.id,
                route: route,
                sessionID: sessionID,
                canonical: entry.kind == .canonicalBotChat,
                title: entry.title,
                subtitle: entry.subtitle)
        }
    }
}

struct OpenFleetConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Fleet Conversation"
    static let description = IntentDescription(
        "Open one of your saved Hermes Fleet conversations.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Conversation")
    var conversation: FleetConversationShortcutEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(FleetConversationDeepLink.url(for: conversation)))
    }
}

struct HermesFleetShortcuts: AppShortcutsProvider {
    // AppIntents' iOS 27 SDK models AppShortcut as non-Sendable even though
    // the provider registry is immutable after initialization.
    nonisolated(unsafe) static let appShortcuts: [AppShortcut] = [
            AppShortcut(
                intent: OpenFleetConversationIntent(),
                phrases: ["Open a Fleet conversation in \(.applicationName)"],
                shortTitle: "Open Conversation",
                systemImageName: "bubble.left.and.bubble.right"),
    ]
}

/// The app-private URL handoff used by the intent. Query items are validated
/// before navigation and carry only source-qualified identity.
enum FleetConversationDeepLink {
    private static let scheme = "hermes-fleet"
    private static let host = "conversation"

    static func url(for entity: FleetConversationShortcutEntity) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "gateway", value: entity.route.gatewayID.rawValue),
            URLQueryItem(name: "profile", value: entity.route.profileSlug.rawValue),
            URLQueryItem(name: "session", value: entity.sessionID),
            URLQueryItem(name: "canonical", value: entity.canonical ? "1" : "0"),
        ]
        // All entity values were validated by the query provider.
        return components.url!
    }

    static func target(from url: URL) -> (route: Route, sessionID: String, canonical: Bool)? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, values[item.name] == nil else { return nil }
            values[item.name] = value
        }
        guard let gateway = values["gateway"],
              let profile = values["profile"],
              let sessionID = values["session"],
              let canonicalRaw = values["canonical"],
              let canonical = ["0": false, "1": true][canonicalRaw],
              let route = Route(
                validating: GatewayID(rawValue: gateway),
                profileSlug: ProfileSlug(rawValue: profile)),
              RoutingGuard.isValidSessionKey(sessionID) else { return nil }
        return (route, sessionID, canonical)
    }
}
