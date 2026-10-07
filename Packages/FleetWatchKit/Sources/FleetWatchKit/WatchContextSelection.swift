import Foundation

/// The Watch's picker choice. Only IDs; resolved against the latest snapshot
/// on every read, so a removed gateway/bot/conversation is reported, never
/// silently replaced by a different destination.
public struct WatchContextSelection: Codable, Sendable, Hashable {
    public var gatewayID: String?
    public var profileSlug: String?
    /// nil with a bot chosen means the bot OVERVIEW (status only; not a
    /// destination). Main chat is its own conversation entry.
    public var conversationID: String?

    public init(gatewayID: String? = nil, profileSlug: String? = nil, conversationID: String? = nil) {
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
        self.conversationID = conversationID
    }

    public static let empty = WatchContextSelection()
}

public enum WatchContextResolution: Equatable, Sendable {
    case unselected
    case gatewayMissing(gatewayID: String)
    case botMissing(gatewayName: String, profileSlug: String)
    /// Confirmed gone from the phone's full roster.
    case conversationMissing(botName: String, conversationID: String)
    /// Not in the snapshot, but the bot has more conversations than the
    /// snapshot carries and the phone has not confirmed it is gone. NOT removal.
    case conversationNotShown(botName: String, conversationID: String, omitted: Int)
    case resolved(gateway: WatchGateway, bot: WatchBot?, conversation: WatchConversation?)

    public var isFullyTargeted: Bool {
        if case .resolved(_, let bot, _) = self { return bot != nil }
        return false
    }
}

public enum WatchContextResolver {
    public static func resolve(_ selection: WatchContextSelection, in snapshot: WatchSnapshot) -> WatchContextResolution {
        guard let gatewayID = selection.gatewayID else { return .unselected }
        guard let gateway = snapshot.gateways.first(where: { $0.id == gatewayID }) else {
            return .gatewayMissing(gatewayID: gatewayID)
        }
        guard let slug = selection.profileSlug else {
            return .resolved(gateway: gateway, bot: nil, conversation: nil)
        }
        guard let bot = gateway.bots.first(where: { $0.ref.profileSlug == slug }) else {
            return .botMissing(gatewayName: gateway.displayName, profileSlug: slug)
        }
        guard let conversationID = selection.conversationID else {
            return .resolved(gateway: gateway, bot: bot, conversation: nil)
        }
        guard let conversation = bot.conversations.first(where: { $0.id == conversationID }) else {
            let confirmedGone = snapshot.removedPin == WatchConversationPin(
                gatewayID: gatewayID, profileSlug: slug, conversationID: conversationID)
            if !confirmedGone, bot.omittedConversationCount > 0 {
                return .conversationNotShown(botName: bot.displayName, conversationID: conversationID,
                                             omitted: bot.omittedConversationCount)
            }
            return .conversationMissing(botName: bot.displayName, conversationID: conversationID)
        }
        return .resolved(gateway: gateway, bot: bot, conversation: conversation)
    }

    /// Short, always-visible label for the active context ("Mac mini › Scout › Main").
    public static func label(for resolution: WatchContextResolution) -> String {
        switch resolution {
        case .unselected: return "No machine selected"
        case .gatewayMissing: return "Machine removed"
        case .botMissing(let gateway, _): return "\(gateway) › bot removed"
        case .conversationMissing(let bot, _): return "\(bot) › chat removed"
        case .conversationNotShown(let bot, _, _): return "\(bot) › chat not in list"
        case .resolved(let gateway, let bot, let conversation):
            var parts = [gateway.displayName]
            if let bot { parts.append(bot.displayName) }
            if bot != nil {
                parts.append(conversation.map { $0.isMain ? "Main chat" : $0.title } ?? "Overview")
            }
            return parts.joined(separator: " › ")
        }
    }
}
