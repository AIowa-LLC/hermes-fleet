import Foundation
import FleetCore

/// Modern `profiles.list` decoding for Bot Mode — canonical_session,
/// worker_session, ui_meta, ui_meta_revisions, bot_mode_protocol.
///
/// Wire ground truth (tui_gateway/methods_profiles.py @ upstream
/// 08b140d14e6c1d49f9b7ad02c9437fe940d54d65):
/// - Row: `{name, path, is_default, model, provider, description,
///   display_name, skill_count, [last_session, worker_session,
///   canonical_session,] ui_meta_revisions, [ui_meta,] has_avatar}` (order
///   is wire-visible; revisions ALWAYS precede ui_meta — :224-234).
/// - `canonical_session` (:138-172): `{id, resolved_id, root_title, title,
///   preview, started_at, last_active, message_count}` — `resolved_id` is
///   the live compression-tip id; `id` the durable registry row.
/// - `worker_session` (:191-194): `{id, source, title, last_active}`.
/// - Top-level `bot_mode_protocol: bool` (:252-254) — clients must NOT
///   append the Bot Mode protocol to SOUL.md.
///
/// Older gateways omit every new field — decode is tolerant and reports
/// honest degradation (nil canonical/worker/revisions), never fabrication.
public enum ModernProfilesDecoder {
    /// Decode a full profiles.list result into descriptors + the
    /// bot_mode_protocol flag.
    public static func decode(_ result: JSONValue) throws -> (profiles: [ProfileDescriptor], botModeProtocol: Bool) {
        guard let profiles = result["profiles"]?.arrayValue else {
            throw RosterError.malformedPayload("profiles.list result missing 'profiles' array")
        }
        let botModeProtocol = result["bot_mode_protocol"]?.boolValue ?? false
        return (profiles.compactMap { decodeProfile($0) }, botModeProtocol)
    }

    /// Decode one row (tolerant; unknown keys retained via uiMeta).
    public static func decodeProfile(_ json: JSONValue) -> ProfileDescriptor? {
        guard let object = json.objectValue else { return nil }
        guard let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        return ProfileDescriptor(
            name: name,
            path: object["path"]?.stringValue ?? "",
            isDefault: object["is_default"]?.boolValue ?? false,
            model: object["model"]?.stringValue,
            provider: object["provider"]?.stringValue,
            profileDescription: object["description"]?.stringValue,
            displayName: object["display_name"]?.stringValue,
            skillCount: object["skill_count"]?.numberValue.map(Int.init) ?? 0,
            hasAvatar: object["has_avatar"]?.boolValue ?? false,
            lastSession: object["last_session"].flatMap(decodeLegacySession),
            gatewayRunning: object["gateway_running"]?.boolValue ?? false,
            canonicalSession: object["canonical_session"].flatMap(decodeCanonical),
            workerSession: object["worker_session"].flatMap(decodeWorker),
            uiMetaRevisions: object["ui_meta_revisions"].flatMap(decodeRevisions),
            uiMeta: object["ui_meta"].flatMap(decodeRawMeta)
        )
    }

    /// last_session row: `{id, title, preview, started_at, last_active, message_count}`.
    /// FOS-5 (SPEC §10): `last_active` is decoded and preserved (0 when the
    /// gateway omits it) so a later ranking upgrade can consume it — current
    /// sort semantics remain `startedAt`-based.
    static func decodeLegacySession(_ json: JSONValue?) -> SessionSummary? {
        guard let o = json?.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        return SessionSummary(
            id: id,
            title: o["title"]?.stringValue ?? "",
            preview: o["preview"]?.stringValue ?? "",
            startedAt: o["started_at"]?.numberValue ?? 0,
            lastActive: o["last_active"]?.numberValue ?? 0,
            messageCount: o["message_count"]?.numberValue.map(Int.init) ?? 0,
            source: nil
        )
    }

    static func decodeCanonical(_ json: JSONValue?) -> CanonicalSessionRef? {
        guard let o = json?.objectValue,
              let id = o["id"]?.stringValue,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // QA hardening: reject empty/malformed resolved ids at the decode
        // boundary (empty string decodes as absent, not as an open target).
        let resolved = o["resolved_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CanonicalSessionRef(
            id: id,
            resolvedID: (resolved?.isEmpty == false) ? resolved : nil,
            rootTitle: o["root_title"]?.stringValue,
            title: o["title"]?.stringValue,
            preview: o["preview"]?.stringValue,
            startedAt: o["started_at"]?.numberValue,
            lastActive: o["last_active"]?.numberValue,
            messageCount: o["message_count"]?.numberValue.map(Int.init)
        )
    }

    static func decodeWorker(_ json: JSONValue?) -> WorkerSessionRef? {
        guard let o = json?.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty,
              let lastActive = o["last_active"]?.numberValue else { return nil }
        return WorkerSessionRef(
            id: id,
            source: o["source"]?.stringValue ?? "",
            title: o["title"]?.stringValue,
            lastActive: lastActive
        )
    }

    static func decodeRevisions(_ json: JSONValue?) -> MetadataRevisions? {
        guard let o = json?.objectValue else { return nil }
        var revisions: [String: Int] = [:]
        for (key, value) in o {
            if let n = value.numberValue, n >= 0 {
                revisions[key] = Int(n)
            }
        }
        return MetadataRevisions(revisions: revisions)
    }

    static func decodeRawMeta(_ json: JSONValue?) -> [String: MetadataValue]? {
        guard let o = json?.objectValue else { return nil }
        return o.mapValues(toMetadataValue)
    }

    /// Convert a networking JSONValue tree into a FleetCore MetadataValue
    /// tree (FleetCore cannot import FleetNetworking).
    public static func toMetadataValue(_ json: JSONValue) -> MetadataValue {
        switch json {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(toMetadataValue))
        case .object(let o): return .object(o.mapValues(toMetadataValue))
        }
    }
}
