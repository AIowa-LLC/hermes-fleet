import Foundation
import FleetCore

/// Errors for Bot Mode profile operations.
public enum BotModeProfileError: Error, Sendable, Equatable, LocalizedError {
    case notConnected
    case malformedPayload(String)
    case rpcFailed(String)
    case profileNotFound(String)
    case invalidRoute(String)
    /// CAS conflict: the gateway rejected the whole write; carries current
    /// revisions and per-key conflicts so the caller can refresh and re-edit
    /// (checkpoint 5: recoverable conflict, never silent overwrite).
    case metadataConflict(revisions: [String: Int], conflicts: [String: ExpectedActual])
    /// Model switch needs explicit confirmation (methods_profiles.py:482-501).
    case confirmRequired(String)
    case unsupportedMethod(String)

    public struct ExpectedActual: Hashable, Sendable, Codable {
        public let expected: Int
        public let actual: Int
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "gateway not connected"
        case .malformedPayload(let s): return "malformed payload: \(s)"
        case .rpcFailed(let s): return "RPC failed: \(s)"
        case .profileNotFound(let s): return "profile not found: \(s)"
        case .invalidRoute(let s): return "invalid route: \(s)"
        case .metadataConflict: return "metadata was changed by another client — reload and try again"
        case .confirmRequired(let s): return s
        case .unsupportedMethod(let s): return "gateway does not support \(s) — update the gateway"
        }
    }
}

/// Bot Mode profile operations over the shared per-gateway transport:
/// `profiles.describe` / `profiles.configure` (ui_meta CAS) /
/// `profiles.create` / `profiles.set_asset` / `profiles.get_asset`, plus the
/// canonical-chat title-exact `session.list` lookup and safe creation.
///
/// Wire ground truth (tui_gateway/methods_profiles.py, methods_session.py):
/// - configure sections: `ui_meta` + `ui_meta_expected_revisions` (per-key
///   CAS, whole-write reject), `soul`, `description`, `model`+`provider`
///   (+`confirm_expensive_model`), `disabled_skills`, `enabled_toolsets`,
///   `enabled_mcp_servers` — response `{ok, applied{...}}` (:563-586).
/// - set_asset avatar: data URL or bare base64, ≤2MB, PNG/JPEG/WebP only
///   (:595-630). get_asset: `{found, mime, size, data}` (:633-647).
/// - session.list `{profile, title, include_hidden: true}` exact-title rows
///   carry `resolved_id` (methods_session.py:363-387).
/// - session.create `{profile, title, hidden: true, follow_profile_config:
///   true}` for canonical creation (canonical-chat.ts:348-363).
public struct GatewayBotModeClient {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - canonical chat

    /// Title-exact hidden lookup of the canonical "Bot Chat" session on the
    /// bot's OWN gateway/profile. Rows returned re-verified for the exact
    /// title; `resolved_id` (compression tip) preferred as the open id.
    public func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        let result = try await request(method: "session.list", params: .object([
            "profile": .string(profile),
            "title": .string(BotModeContract.canonicalChatTitle),
            "include_hidden": .bool(true),
            "limit": .number(200),
        ]))
        guard let sessions = result["sessions"]?.arrayValue else {
            throw BotModeProfileError.malformedPayload("session.list missing 'sessions'")
        }
        let rows: [CanonicalLookupRow] = sessions.compactMap { json in
            guard let o = json.objectValue,
                  let id = o["id"]?.stringValue, !id.isEmpty,
                  o["title"]?.stringValue == BotModeContract.canonicalChatTitle else { return nil }
            let resolved = o["resolved_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CanonicalLookupRow(
                id: id,
                resolvedID: (resolved?.isEmpty == false) ? resolved : nil,
                title: o["title"]?.stringValue ?? "",
                preview: o["preview"]?.stringValue ?? "",
                messageCount: o["message_count"]?.numberValue.map(Int.init) ?? 0
            )
        }
        return CanonicalLookup(rows: rows)
    }

    /// Safe canonical creation (registry-miss path only): hidden session +
    /// eager exact title. Returns the runtime/stored session id.
    public func createCanonicalChat(profile: String) async throws -> String {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        let created = try await request(method: "session.create", params: .object([
            "profile": .string(profile),
            "title": .string(BotModeContract.canonicalChatTitle),
            "hidden": .bool(true),
            "follow_profile_config": .bool(true),
        ]))
        guard let id = created["session_id"]?.stringValue ?? created["stored_session_id"]?.stringValue,
              !id.isEmpty else {
            throw BotModeProfileError.malformedPayload("session.create missing session id")
        }
        // Eager title materializes the lazy registry row before any open
        // (canonical-chat.ts:378-386).
        _ = try? await request(method: "session.title", params: .object([
            "session_id": .string(id),
            "title": .string(BotModeContract.canonicalChatTitle),
        ]))
        // Adopt-before-mint: a title rejected as already-in-use means the
        // registry row exists — re-consult and adopt the winner instead of
        // prompting into the stray session (canonical-chat.ts:387-413).
        // The lookup above already returns exact-title rows; the caller
        // re-resolves on conflict.
        return id
    }

    // MARK: - metadata CAS

    /// Write bot metadata under ui_meta key `hermes-bots` with per-key CAS.
    ///
    /// - Parameters:
    ///   - expectedRevision: revision the caller read; nil sends the write
    ///     without CAS only when the gateway never advertised revisions
    ///     (older gateway — honest degradation, logged by the caller).
    ///   - previousRaw: the previously decoded raw `hermes-bots` object, so
    ///     unknown keys round-trip.
    public func writeBotMetadata(
        profile: String,
        metadata: BotModeMetadata,
        expectedRevision: Int?,
        previousRaw: MetadataValue?
    ) async throws -> MetadataWriteReceipt {
        var wireObject = metadata.toWire()
        // Round-trip unknown keys from the previous raw value.
        if let previous = previousRaw?.objectValue {
            for (key, value) in previous where wireObject[key] == nil {
                wireObject[key] = value
            }
        }
        var params: [String: JSONValue] = [
            "name": .string(profile),
            "ui_meta": .object(["hermes-bots": .object(wireObject.toJSONObject())]),
        ]
        if let expectedRevision {
            params["ui_meta_expected_revisions"] = .object([
                "hermes-bots": .number(Double(expectedRevision))
            ])
        }
        let result = try await request(method: "profiles.configure", params: .object(params))
        return try Self.decodeConfigureReceipt(result)
    }

    /// Clear the `hermes-bots` metadata key (deletion via null value).
    public func clearBotMetadata(profile: String, expectedRevision: Int) async throws -> MetadataWriteReceipt {
        let result = try await request(method: "profiles.configure", params: .object([
            "name": .string(profile),
            "ui_meta": .object(["hermes-bots": .null]),
            "ui_meta_expected_revisions": .object([
                "hermes-bots": .number(Double(expectedRevision))
            ]),
        ]))
        return try Self.decodeConfigureReceipt(result)
    }

    // MARK: - assets

    public func getAvatar(profile: String) async throws -> Data? {
        let result = try await request(method: "profiles.get_asset", params: .object([
            "name": .string(profile),
            "asset": .string("avatar"),
        ]))
        guard result["found"]?.boolValue == true,
              let dataURL = result["data"]?.stringValue else { return nil }
        return Self.decodeDataURL(dataURL)
    }

    public func setAvatar(profile: String, dataURL: String) async throws {
        let result = try await request(method: "profiles.set_asset", params: .object([
            "name": .string(profile),
            "asset": .string("avatar"),
            "data": .string(dataURL),
        ]))
        _ = result
    }

    // MARK: - transport plumbing

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        if !isTransportReady {
            try await transport.connect()
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    static func decodeConfigureReceipt(_ result: JSONValue) throws -> MetadataWriteReceipt {
        // `{ok, applied: {ui_meta: bool, ui_meta_conflicts?: {key: {expected, actual}},
        //  ui_meta_revisions?: {key: newRev}}}` (methods_profiles.py:436-479).
        let applied = result["applied"]?.objectValue ?? [:]
        let uiMetaApplied = applied["ui_meta"]?.boolValue ?? false
        var newRevisions: [String: Int] = [:]
        if let revs = applied["ui_meta_revisions"]?.objectValue {
            for (key, value) in revs {
                if let n = value.numberValue { newRevisions[key] = Int(n) }
            }
        }
        var conflicts: [String: BotModeProfileError.ExpectedActual] = [:]
        if let conflictObject = applied["ui_meta_conflicts"]?.objectValue {
            for (key, value) in conflictObject {
                if let o = value.objectValue,
                   let expected = o["expected"]?.numberValue.map(Int.init),
                   let actual = o["actual"]?.numberValue.map(Int.init) {
                    conflicts[key] = BotModeProfileError.ExpectedActual(expected: expected, actual: actual)
                }
            }
        }
        if !uiMetaApplied && !conflicts.isEmpty {
            throw BotModeProfileError.metadataConflict(
                revisions: newRevisions, conflicts: conflicts)
        }
        if !uiMetaApplied {
            throw BotModeProfileError.rpcFailed("profiles.configure did not apply the ui_meta section")
        }
        return MetadataWriteReceipt(applied: true, newRevisions: newRevisions)
    }

    static func mapError(_ error: JSONRPCError) -> BotModeProfileError {
        switch error.code {
        case 4063, 4064: return .profileNotFound(error.message)
        case 5064: return .rpcFailed(error.message)
        case -32601: return .unsupportedMethod(error.message)
        default: return .rpcFailed("\(error.message) (\(error.code))")
        }
    }

    static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let range = dataURL.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(dataURL[range.upperBound...]))
    }
}

/// Rows returned by the canonical title-exact lookup.
public struct CanonicalLookup: Sendable {
    public let rows: [CanonicalLookupRow]

    public init(rows: [CanonicalLookupRow]) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var first: CanonicalLookupRow? { rows.first }
}

public struct CanonicalLookupRow: Hashable, Sendable {
    public let id: String
    public let resolvedID: String?
    public let title: String
    public let preview: String
    public let messageCount: Int

    public init(id: String, resolvedID: String? = nil, title: String, preview: String = "", messageCount: Int = 0) {
        self.id = id
        self.resolvedID = resolvedID
        self.title = title
        self.preview = preview
        self.messageCount = messageCount
    }
}

/// Receipt of a successful CAS write.
public struct MetadataWriteReceipt: Hashable, Sendable {
    public let applied: Bool
    public let newRevisions: [String: Int]

    public init(applied: Bool, newRevisions: [String: Int]) {
        self.applied = applied
        self.newRevisions = newRevisions
    }
}

extension [String: MetadataValue] {
    /// Convert to a networking JSONValue object for the wire.
    func toJSONObject() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in self {
            out[key] = toJSONValue(value)
        }
        return out
    }

    private func toJSONValue(_ value: MetadataValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map { toJSONValue($0) })
        case .object(let o): return .object(o.mapValues { toJSONValue($0) })
        }
    }
}
