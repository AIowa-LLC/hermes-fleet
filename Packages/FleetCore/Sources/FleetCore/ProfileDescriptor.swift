import Foundation

/// A profile (bot) as reported by the gateway's `profiles.list` method.
///
/// Wire shape (verified in `tui_gateway/methods_profiles.py`, `profiles.list`):
/// `{name, path, is_default, model, provider, description, display_name,
/// skill_count, has_avatar, last_session?...}`. `name` is the routing slug;
/// `display_name` is presentation-only and is NEVER substituted for `name`
/// when building a `Route` (spec §31 Profiles: "display name is never
/// substituted for routing slug").
public struct ProfileDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// Routing slug (`ProfileSlug`) — the identity half used to build routes.
    public let name: String
    /// Profile home directory on the gateway host.
    public let path: String
    public let isDefault: Bool
    public let model: String?
    public let provider: String?
    public let profileDescription: String?
    /// Presentation name; never used for routing.
    public let displayName: String?
    public let skillCount: Int
    public let hasAvatar: Bool
    /// Most recent human-facing conversation summary, when the gateway sent
    /// `include_sessions` (default true).
    public let lastSession: SessionSummary?
    /// Server truth from `profiles.list`: whether this profile runs its OWN
    /// gateway process (a standing per-profile listener). P0-7 scope note:
    /// the gateway is a PROFILE MULTIPLEXER — every profile it lists is
    /// chat-reachable through the one shared connection — so this field is a
    /// SECONDARY "own gateway process" badge, NEVER the primary online/offline
    /// presence. Presence comes from the owning gateway connection's roster
    /// outcome (see `FleetRosterSnapshot.botPresence(on:)`).
    public let gatewayRunning: Bool
    /// Bot Mode: canonical "Bot Chat" session resolved by the gateway
    /// (`canonical_session` — methods_profiles.py:138-172). Identity info —
    /// the exact-title registry row; nil on older gateways that omit it.
    public let canonicalSession: CanonicalSessionRef?
    /// Bot Mode: newest denied-source (kanban/tool) worker session — a
    /// worker-activity signal (methods_profiles.py:191-194).
    public let workerSession: WorkerSessionRef?
    /// Bot Mode per-key ui_meta revisions (ALWAYS present on modern
    /// gateways; `{}` for new profiles — methods_profiles.py:224-234).
    /// Older gateways omit the field entirely → nil = no CAS support.
    public let uiMetaRevisions: MetadataRevisions?
    /// Raw profile ui_meta (unknown keys preserved verbatim).
    public let uiMeta: [String: MetadataValue]?

    public var slug: ProfileSlug { ProfileSlug(rawValue: name) }

    /// Identity for list rendering — the slug, which is unique per gateway.
    public var id: String { name }

    /// Decoded `hermes-bots` Bot Mode metadata, when present.
    public var botModeMetadata: BotModeMetadata? {
        BotModeMetadata(metadataValue: uiMeta?[BotModeContract.botsMetaKey])
    }

    public init(
        name: String,
        path: String,
        isDefault: Bool = false,
        model: String? = nil,
        provider: String? = nil,
        profileDescription: String? = nil,
        displayName: String? = nil,
        skillCount: Int = 0,
        hasAvatar: Bool = false,
        lastSession: SessionSummary? = nil,
        gatewayRunning: Bool = false,
        canonicalSession: CanonicalSessionRef? = nil,
        workerSession: WorkerSessionRef? = nil,
        uiMetaRevisions: MetadataRevisions? = nil,
        uiMeta: [String: MetadataValue]? = nil
    ) {
        self.name = name
        self.path = path
        self.isDefault = isDefault
        self.model = model
        self.provider = provider
        self.profileDescription = profileDescription
        self.displayName = displayName
        self.skillCount = skillCount
        self.hasAvatar = hasAvatar
        self.lastSession = lastSession
        self.gatewayRunning = gatewayRunning
        self.canonicalSession = canonicalSession
        self.workerSession = workerSession
        self.uiMetaRevisions = uiMetaRevisions
        self.uiMeta = uiMeta
    }

    /// The name to display for this bot: `display_name` when present, else the
    /// slug. This is presentation-only and never participates in routing.
    public var resolvedDisplayName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return name
    }
}
