import Foundation
import CryptoKit

public enum WatchCodecError: Error, Equatable {
    case tooLarge(Int)
    case malformed
    case unsupportedSchema(Int)
    case wrongFlavor
}

/// Encodes protocol values as one `Data` entry in a WatchConnectivity
/// dictionary, with a hard size bound on both ends.
public enum WatchCodec {
    public static let key = "fleet.watch.v1"
    public static let maxPayloadBytes = 48 * 1024

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    public static func pack<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder().encode(value)
        guard data.count <= maxPayloadBytes else { throw WatchCodecError.tooLarge(data.count) }
        return [key: data]
    }

    public static func unpack<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) throws -> T {
        guard let data = dictionary[key] as? Data else { throw WatchCodecError.malformed }
        guard data.count <= maxPayloadBytes else { throw WatchCodecError.tooLarge(data.count) }
        do { return try decoder().decode(type, from: data) } catch { throw WatchCodecError.malformed }
    }

    /// Validates a snapshot's schema and flavor before the Watch trusts it.
    public static func validate(_ snapshot: WatchSnapshot, expecting flavor: WatchAppFlavor) throws {
        guard snapshot.schemaVersion == WatchSnapshot.schemaVersion else {
            throw WatchCodecError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.flavor == flavor else { throw WatchCodecError.wrongFlavor }
    }

    /// Hex SHA-256 of the exact command string the phone observed.
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps a snapshot inside the payload budget by trimming least important
/// content first, and records that it did so (limited coverage is surfaced,
/// never hidden).
public enum WatchSnapshotBudget {
    public static let maxConversationsPerBot = 6
    public static let maxRunningPerGateway = 8
    public static let maxApprovals = 10
    public static let maxAttention = 12

    /// `pinned` keeps one conversation in its bot's list even beyond the cap
    /// (when it still exists in the untrimmed list).
    public static func trimmed(_ snapshot: WatchSnapshot, pinned: WatchConversationPin? = nil) -> WatchSnapshot {
        let gateways = snapshot.gateways.map { gateway in
            WatchGateway(
                id: gateway.id, displayName: gateway.displayName, status: gateway.status,
                coverage: gateway.coverage, observedAt: gateway.observedAt,
                bots: gateway.bots.map { bot in
                    let pin = (pinned?.gatewayID == bot.ref.gatewayID && pinned?.profileSlug == bot.ref.profileSlug)
                        ? pinned?.conversationID : nil
                    return WatchBot(ref: bot.ref, displayName: bot.displayName, activity: bot.activity,
                                    conversations: capped(bot.conversations, keeping: pin),
                                    totalConversations: bot.totalConversations ?? bot.conversations.count,
                                    mainChatStatus: bot.mainChatStatus, mainChatDiagnostic: bot.mainChatDiagnostic,
                                    conversationsObservedAt: bot.conversationsObservedAt)
                },
                running: Array(gateway.running.prefix(maxRunningPerGateway)),
                rosterObservedAt: gateway.rosterObservedAt,
                conversationsObservedAt: gateway.conversationsObservedAt)
        }
        return WatchSnapshot(
            flavor: snapshot.flavor, generation: snapshot.generation, builtAt: snapshot.builtAt,
            contentVisible: snapshot.contentVisible, isFixture: snapshot.isFixture,
            gateways: gateways,
            attention: Array(snapshot.attention.prefix(maxAttention)),
            approvals: Array(snapshot.approvals.prefix(maxApprovals)),
            removedPin: snapshot.removedPin)
    }

    static func capped(_ all: [WatchConversation], keeping pinnedID: String?) -> [WatchConversation] {
        let head = Array(all.prefix(maxConversationsPerBot))
        guard let pinnedID, !head.contains(where: { $0.id == pinnedID }),
              let pinned = all.first(where: { $0.id == pinnedID }) else { return head }
        return Array(head.prefix(maxConversationsPerBot - 1)) + [pinned]
    }
}
