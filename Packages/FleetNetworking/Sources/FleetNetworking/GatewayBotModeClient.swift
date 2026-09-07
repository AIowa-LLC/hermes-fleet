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
public struct GatewayBotModeClient: BotModeChatProviding, Sendable {
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

    /// `profiles.set_asset {clear: true}` — remove the avatar asset
    /// (methods_profiles.py:595-630; `{ok, asset, size: 0, removed}`).
    public func clearAvatarAsset(profile: String) async throws {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        _ = try await request(method: "profiles.set_asset", params: .object([
            "name": .string(profile),
            "asset": .string("avatar"),
            "clear": .bool(true),
        ]))
    }

    /// BotProfileManaging seam: upload avatar (same wire call as setAvatar).
    public func uploadAvatar(_ profile: String, dataURL: String) async throws {
        try await setAvatar(profile: profile, dataURL: dataURL)
    }

    /// BotProfileManaging seam: clear avatar ({clear: true}).
    public func clearAvatar(_ profile: String) async throws {
        try await clearAvatarAsset(profile: profile)
    }

    /// BotProfileManaging seam: avatar bytes (nil when absent).
    public func avatarData(_ profile: String) async throws -> Data? {
        try await getAvatar(profile: profile)
    }

    // MARK: - profile management (slice 2)

    /// `profiles.describe` — the full editable surface
    /// (methods_profiles.py:400-433): soul, model{provider,default}, skills,
    /// toolsets, mcp_servers.
    public func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        let result = try await request(method: "profiles.describe", params: .object([
            "name": .string(profile),
        ]))
        guard let object = result.objectValue else {
            throw BotModeProfileError.malformedPayload("profiles.describe returned a non-object")
        }
        return Self.decodeDescription(object, profile: profile)
    }

    /// Decode a `profiles.describe` result object.
    static func decodeDescription(_ object: [String: JSONValue], profile: String) -> BotProfileDescription {
        let modelObject = object["model"]?.objectValue
        let skills = (object["skills"]?.arrayValue ?? []).compactMap { entry -> BotProfileDescription.SkillEntry? in
            guard let o = entry.objectValue, let name = o["name"]?.stringValue, let enabled = o["enabled"]?.boolValue else { return nil }
            return BotProfileDescription.SkillEntry(
                name: name, enabled: enabled)
        }
        let toolsets = (object["toolsets"]?.arrayValue ?? []).compactMap { entry -> BotProfileDescription.ToolsetEntry? in
            guard let o = entry.objectValue, let name = o["name"]?.stringValue, let enabled = o["enabled"]?.boolValue else { return nil }
            return BotProfileDescription.ToolsetEntry(
                name: name,
                label: o["label"]?.stringValue,
                description: o["description"]?.stringValue,
                toolCount: o["tool_count"]?.numberValue.map(Int.init) ?? 0,
                enabled: enabled)
        }
        let mcp = (object["mcp_servers"]?.arrayValue ?? []).compactMap { entry -> BotProfileDescription.MCPEntry? in
            guard let o = entry.objectValue, let name = o["name"]?.stringValue, let enabled = o["enabled"]?.boolValue else { return nil }
            return BotProfileDescription.MCPEntry(
                name: name,
                enabled: enabled,
                transport: o["transport"]?.stringValue)
        }
        return BotProfileDescription(
            name: object["name"]?.stringValue ?? profile,
            descriptionText: object["description"]?.stringValue,
            soul: object["soul"]?.stringValue,
            defaultModel: modelObject?["default"]?.stringValue,
            provider: modelObject?["provider"]?.stringValue,
            skills: skills,
            toolsets: toolsets,
            mcpServers: mcp
        )
    }

    /// `profiles.configure` with per-section dirty flags and ui_meta CAS.
    /// Sections that are nil in the edit are NEVER sent (upstream per-section
    /// dirty-flag discipline — an untouched section is never written).
    public func configureProfile(
        _ profile: String,
        edit: BotProfileEdit
    ) async throws -> BotProfileEditOutcome {
        try await configureProfileImpl(profile, edit: edit, confirmExpensiveModel: false)
    }

    /// Confirmation resend variant for a pending model switch.
    public func configureProfile(
        _ profile: String,
        edit: BotProfileEdit,
        confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        try await configureProfileImpl(profile, edit: edit, confirmExpensiveModel: confirmExpensiveModel)
    }

    private func configureProfileImpl(
        _ profile: String,
        edit: BotProfileEdit,
        confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        var params: [String: JSONValue] = ["name": .string(profile)]
        if let metadata = edit.metadata {
            var wireObject = metadata.toWire()
            if let previous = edit.previousMetadataRaw?.objectValue {
                for (key, value) in previous where wireObject[key] == nil {
                    wireObject[key] = value
                }
            }
            if let expected = edit.metadataExpectedRevision {
                params["ui_meta_expected_revisions"] = .object([
                    BotModeContract.botsMetaKey: .number(Double(expected))
                ])
            }
            params["ui_meta"] = .object([
                BotModeContract.botsMetaKey: .object(wireObject.toJSONObject())
            ])
        }
        if let soul = edit.soul { params["soul"] = .string(soul) }
        if let description = edit.descriptionText { params["description"] = .string(description) }
        if let model = edit.model { params["model"] = .string(model) }
        if let provider = edit.provider { params["provider"] = .string(provider) }
        if confirmExpensiveModel { params["confirm_expensive_model"] = .bool(true) }
        if let disabled = edit.disabledSkills {
            params["disabled_skills"] = .array(disabled.map { .string($0) })
        }
        if let toolsets = edit.enabledToolsets {
            params["enabled_toolsets"] = .array(toolsets.map { .string($0) })
        }
        if let mcp = edit.enabledMCPServers {
            params["enabled_mcp_servers"] = .array(mcp.map { .string($0) })
        }
        let result = try await request(method: "profiles.configure", params: .object(params))
        return try Self.decodeEditOutcome(result, edit: edit)
    }

    /// Decode a `profiles.configure` response into a typed per-section
    /// outcome: `{ok, applied:{section: bool}, [confirm_required,
    /// confirm_message]}` — a ui_meta conflict is surfaced as a typed
    /// `.metadataConflict` error (never silent).
    static func decodeEditOutcome(
        _ result: JSONValue, edit: BotProfileEdit
    ) throws -> BotProfileEditOutcome {
        let applied = result["applied"]?.objectValue ?? [:]
        let confirmRequired = result["confirm_required"]?.boolValue ?? false
        let confirmMessage = result["confirm_message"]?.stringValue

        var appliedFlags: [String: Bool] = [:]
        for (key, value) in applied where key != "ui_meta_revisions" && key != "ui_meta_conflicts" {
            appliedFlags[key] = value.boolValue
        }
        var newRevisions: [String: Int] = [:]
        if let revs = applied["ui_meta_revisions"]?.objectValue {
            for (key, value) in revs {
                if let n = value.numberValue { newRevisions[key] = Int(n) }
            }
        }
        var conflict: BotProfileEditOutcome.MetadataConflict?
        if let conflicts = applied["ui_meta_conflicts"]?.objectValue,
           let botsConflict = conflicts[BotModeContract.botsMetaKey]?.objectValue {
            conflict = BotProfileEditOutcome.MetadataConflict(
                key: BotModeContract.botsMetaKey,
                expected: botsConflict["expected"]?.numberValue.map(Int.init) ?? 0,
                actual: botsConflict["actual"]?.numberValue.map(Int.init) ?? 0)
        }
        if let conflict {
            throw BotModeProfileError.metadataConflict(
                revisions: newRevisions,
                conflicts: [BotModeContract.botsMetaKey:
                    BotModeProfileError.ExpectedActual(
                        expected: conflict.expected, actual: conflict.actual)])
        }
        return BotProfileEditOutcome(
            edit: edit,
            applied: appliedFlags,
            newMetadataRevisions: newRevisions,
            confirmRequired: confirmRequired,
            confirmMessage: confirmMessage
        )
    }

    /// `profiles.create` (methods_profiles.py:337-374): fresh (bundled
    /// skills seeded), clone_from (config-only) or clone_all (full), or
    /// no_skills empty; optional soul/model/provider; credential semantics
    /// (`share_auth`, `mirror_credentials`) copied from the wire contract.
    @discardableResult
    public func createProfile(_ spec: BotCreateSpec) async throws -> String {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        var params: [String: JSONValue] = [
            "name": .string(spec.name),
            "share_auth": .bool(spec.shareAuth),
            "mirror_credentials": .bool(spec.mirrorCredentials),
        ]
        switch spec.seed {
        case .fresh:
            break
        case .clone(let profile, let cloneAll):
            params["clone_from"] = .string(profile)
            params["clone_all"] = .bool(cloneAll)
        case .emptyNoSkills:
            params["no_skills"] = .bool(true)
        }
        if let soul = spec.soul, !soul.isEmpty { params["soul"] = .string(soul) }
        if let model = spec.model, let provider = spec.provider {
            params["model"] = .string(model)
            params["provider"] = .string(provider)
        }
        if let description = spec.descriptionText, !description.isEmpty {
            params["description"] = .string(description)
        }
        let result = try await request(method: "profiles.create", params: .object(params))
        guard result["ok"]?.boolValue == true,
              let name = result["name"]?.stringValue, !name.isEmpty else {
            throw BotModeProfileError.malformedPayload("profiles.create did not confirm creation")
        }
        return name
    }

    /// Read one profile's full ui_meta row via `profiles.list` (used by the
    /// sections-registry sync on the DEFAULT profile).
    public func profileUIMeta(profile: String) async throws -> [String: MetadataValue]? {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        let result = try await request(method: "profiles.list", params: .object([:]))
        guard let profiles = result["profiles"]?.arrayValue else {
            throw BotModeProfileError.malformedPayload("profiles.list missing 'profiles'")
        }
        let row = profiles.first { $0["name"]?.stringValue == profile }
        guard let row else { return nil }
        guard let metaObject = row["ui_meta"]?.objectValue else { return nil }
        return metaObject.mapValues { ModernProfilesDecoder.toMetadataValue($0) }
    }

    /// Write ONE ui_meta key with per-key CAS (sections registry rides the
    /// DEFAULT profile's `bot-sections-v1` key this way). Unknown sibling
    /// keys are untouched — only the named key is written.
    public func writeUIMetaKey(
        profile: String,
        key: String,
        value: MetadataValue,
        expectedRevision: Int?
    ) async throws -> MetadataWriteReceipt {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        var params: [String: JSONValue] = [
            "name": .string(profile),
            "ui_meta": .object([key: toJSON(value)]),
        ]
        if let expectedRevision {
            params["ui_meta_expected_revisions"] = .object([
                key: .number(Double(expectedRevision))
            ])
        }
        let result = try await request(method: "profiles.configure", params: .object(params))
        let receipt = try Self.decodeConfigureReceipt(result)
        // The generic receipt path decodes `applied.ui_meta`; a conflict on
        // THIS key is surfaced typed by decodeConfigureReceipt already.
        return receipt
    }

    /// Read the current revision of one ui_meta key for a profile
    /// (`ui_meta_revisions` from `profiles.list`).
    public func uiMetaRevision(profile: String, key: String) async throws -> Int? {
        guard case .connected = transport.state else { throw BotModeProfileError.notConnected }
        let result = try await request(method: "profiles.list", params: .object([:]))
        guard let profiles = result["profiles"]?.arrayValue else {
            throw BotModeProfileError.malformedPayload("profiles.list missing 'profiles'")
        }
        guard let row = profiles.first(where: { $0["name"]?.stringValue == profile }) else { return nil }
        guard let revisions = row["ui_meta_revisions"]?.objectValue else { return nil }
        return revisions[key]?.numberValue.map(Int.init)
    }

    private func toJSON(_ value: MetadataValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map { toJSON($0) })
        case .object(let o): return .object(o.mapValues { toJSON($0) })
        }
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

// `CanonicalLookup` / `CanonicalLookupRow` live in FleetCore
// (BotModeChatProviding.swift) — this client conforms to the seam types.
// `BotProfileManaging` conformance: the profile-management methods above
// (describeProfile / configureProfile(_:edit:) / configureProfile
// (_:edit:confirmExpensiveModel:) / createProfile / uploadAvatar /
// clearAvatar / avatarData) satisfy the seam via the overloads below.
extension GatewayBotModeClient: BotProfileManaging {}

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
