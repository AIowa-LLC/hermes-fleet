import Foundation

/// R10-T2 seam: Tapback-style message reactions over a gateway's transport
/// (`message.react`). Lives in FleetCore so FleetUI never imports
/// FleetNetworking (M0 guard); the concrete `GatewayReactionClient`
/// (FleetNetworking) is injected at the composition root.
public protocol ReactionProviding: Sendable {
    /// React to (or clear the local user's reaction on) one message via
    /// `message.react`.
    ///
    /// - Parameters:
    ///   - sessionID: the runtime session id.
    ///   - target: `.durable(rowID:)` for rows with a durable `row_id`,
    ///     `.newest(role:)` for a live row that has not round-tripped
    ///     through a resume yet.
    ///   - emoji: the emoji to set, or `nil` to clear (`emoji: null`).
    /// - Returns: the durable row the write landed on + the message's FULL
    ///   post-write reaction list (server truth for settling the optimistic
    ///   update).
    func react(
        sessionID: String,
        target: MessageReactionTarget,
        emoji: String?
    ) async throws -> MessageReactionResult
}

/// Typed reaction failures (gateway codes mapped, client-side guards
/// included).
public enum ReactionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The transport is not connected to the gateway.
    case notConnected
    /// Gateway error 4023 — neither `row_id` nor a valid `newest_role`.
    case targetRequired(String)
    /// Gateway error 4024 — emoji was an empty string.
    case emptyEmoji(String)
    /// Gateway error 4040 — the row does not exist in this session (or no
    /// message of that role to react to yet).
    case messageNotFound(String)
    /// Gateway error 4001 — the runtime session was reaped; the caller
    /// recovers via `session.resume` on the stored session id
    /// (server.py:3676-3696).
    case sessionNotFound(String)
    /// Gateway error 4025 / 5007 and unmapped codes.
    case rpcFailed(String)
    /// Result envelope did not match the verified wire shape.
    case malformedResponse(detail: String)

    public var description: String {
        switch self {
        case .notConnected: return "gateway not connected"
        case .targetRequired(let s): return s
        case .emptyEmoji(let s): return s
        case .messageNotFound(let s): return s
        case .sessionNotFound(let s): return s
        case .rpcFailed(let s): return s
        case .malformedResponse(let detail): return "malformed gateway response (\(detail))"
        }
    }
}

/// Fail-closed default (no transport): every call throws instead of
/// silently pretending the gateway answered (the
/// `UnsupportedAttachmentStaging` / `UnsupportedGatewayLearning`
/// discipline).
public struct UnsupportedReactionProviding: ReactionProviding {
    public init() {}

    public func react(
        sessionID: String,
        target: MessageReactionTarget,
        emoji: String?
    ) async throws -> MessageReactionResult {
        throw ReactionError.rpcFailed("gateway not configured")
    }
}

/// R10-T2 capability marker mirroring `AttachmentStagingCapable` /
/// `ApprovalsCapable`: concrete sessions expose their reaction surface with
/// ONE cast at build time (`session as? ReactionCapable`) — deliberately NOT
/// a same-named extension property on `ConversationSessionProviding` (that
/// form recurses through swift_dynamicCast; see the ApprovalsCapable note).
/// The view model keeps an `UnsupportedReactionProviding` fail-closed
/// default when the cast fails, so the long-press menu surfaces an honest
/// error instead of pretending.
public protocol ReactionCapable: ConversationSessionProviding {
    var reactions: any ReactionProviding { get }
}
