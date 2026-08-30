import Foundation
import SwiftData

/// One persisted non-secret transcript message row (synthesis §12: SwiftData
/// caches non-secret session history). Fields mirror `SessionMessage` exactly
/// (role/text/timestamp/rowID/displayKind/reasoning/toolName/toolContext).
///
/// **Structural no-secret invariant:** there is NO token, ticket, credential,
/// password, or key field on this or any cache model — secrets live only in
/// Keychain (`KeychainTokenStore` / `KeychainCredentialStore`).
@Model
public final class CachedMessageRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// The runtime session id these rows belong to.
    public var sessionID: String
    /// Transcript order (0-based chronological).
    public var order: Int
    /// `SessionMessageRole.wireValue` ("user"/"assistant"/"tool"/"system"/"unknown").
    public var role: String
    /// The rendered text of the message.
    public var text: String
    /// Persisted authoring time (Unix seconds), when the gateway stamped it.
    public var timestamp: Double?
    /// Durable row identity for the persisted turn, when present.
    public var rowID: String?
    /// Launch-stable client identity (B1): the UUID minted at SessionMessage
    /// construction when the gateway stamped no row_id. Persisted so a fresh
    /// model container reloads the same message with the same id across app
    /// launches (never re-derived from a randomized hash).
    public var clientID: String?
    /// Display-only classification, preserved verbatim.
    public var displayKind: String?
    /// Assistant reasoning/thinking content, when disclosed.
    public var reasoning: String?
    /// Tool message metadata: the tool's name (tool messages only).
    public var toolName: String?
    /// Tool message context (an 80-char preview of the call), tool only.
    public var toolContext: String?

    public init(
        gatewayID: String,
        sessionID: String,
        order: Int,
        role: String,
        text: String,
        timestamp: Double?,
        rowID: String?,
        displayKind: String?,
        reasoning: String?,
        toolName: String?,
        toolContext: String?,
        clientID: String? = nil
    ) {
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.order = order
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.rowID = rowID
        self.clientID = clientID
        self.displayKind = displayKind
        self.reasoning = reasoning
        self.toolName = toolName
        self.toolContext = toolContext
    }
}

/// One persisted per-(gateway, session) seq watermark (spec §9: the highest
/// event `seq` this client observed for a session, surviving relaunch so a
/// reconnecting client can request `session.events.since(lastSeen)`).
@Model
public final class CachedWatermarkRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// The runtime session id these events belong to.
    public var sessionID: String
    /// The highest `seq` observed for that session (0 = none observed yet).
    public var lastSeenSeq: Int

    public init(gatewayID: String, sessionID: String, lastSeenSeq: Int) {
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.lastSeenSeq = lastSeenSeq
    }
}

/// One persisted last-adopted `replay_epoch` per gateway (spec §9.6 /
/// synthesis §12 "relaunch-resume; stale epoch → reset"). When the fresh
/// `gateway.ready.replay_epoch` differs, the client resets stale seq
/// assumptions and rehydrates.
@Model
public final class CachedReplayEpochRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// The last adopted replay_epoch (`nil` = none adopted yet).
    public var epoch: String?

    public init(gatewayID: String, epoch: String?) {
        self.gatewayID = gatewayID
        self.epoch = epoch
    }
}
