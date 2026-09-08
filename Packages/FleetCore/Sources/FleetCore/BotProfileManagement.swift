import Foundation

/// Bot profile management domain: edit payloads with per-section dirty flags,
/// typed partial-success results, duplicate-name minting, and create specs.
///
/// Upstream ground truth (hermes-agent @ originally derived from 08b140d; re-verified against upstream main 966637323e, 2026-09-08):
/// - `profiles.configure` sections: `ui_meta`(+CAS), `soul`, `description`,
///   `model`+`provider`(+`confirm_expensive_model`), `disabled_skills`,
///   `enabled_toolsets`, `enabled_mcp_servers`; response
///   `{ok, applied:{per-section bool}}` — methods_profiles.py:563-586.
///   Desktop's editor gates each section behind its own dirty flag so an
///   untouched section is NEVER written (profile-config.tsx:108-123,548-601).
/// - Model policy: without confirm the model section is PENDING — nothing
///   written, response `confirm_required` + `confirm_message`; the client
///   resends ONLY `{name, model, provider, confirm_expensive_model: true}`
///   (profile-config.tsx:539-545,610-634).
/// - Duplicate: `profiles.create {name, clone_from, description}` with the
///   base's own name; candidate names are `<base>-2`, `-3`, … first free
///   slot; the BASE is truncated, never the suffix (profile-ops.ts #19);
///   look (shape/color/avatar) is copied but `chat`/`created` NEVER are.
/// - Create: `profiles.create {name, description?, clone_from?,
///   clone_all?, no_skills?, soul?, model?, provider?, share_auth?,
///   mirror_credentials?}`; fresh profiles get bundled skills seeded
///   (methods_profiles.py:337-374).

// MARK: - Edit payload (per-section dirty flags)

/// A `profiles.configure` payload where an untouched section is nil and is
/// therefore never written (upstream per-section dirty-flag discipline).
public struct BotProfileEdit: Hashable, Sendable {
    /// New `hermes-bots` ui_meta (whole object; CAS expected revision).
    public var metadata: BotModeMetadata?
    public var metadataExpectedRevision: Int?
    /// Raw previous `hermes-bots` object for unknown-key round-trip.
    public var previousMetadataRaw: MetadataValue?
    public var soul: String?
    public var descriptionText: String?
    public var model: String?
    public var provider: String?
    public var disabledSkills: [String]?
    public var enabledToolsets: [String]?
    public var enabledMCPServers: [String]?

    public init(
        metadata: BotModeMetadata? = nil,
        metadataExpectedRevision: Int? = nil,
        previousMetadataRaw: MetadataValue? = nil,
        soul: String? = nil,
        descriptionText: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        disabledSkills: [String]? = nil,
        enabledToolsets: [String]? = nil,
        enabledMCPServers: [String]? = nil
    ) {
        self.metadata = metadata
        self.metadataExpectedRevision = metadataExpectedRevision
        self.previousMetadataRaw = previousMetadataRaw
        self.soul = soul
        self.descriptionText = descriptionText
        self.model = model
        self.provider = provider
        self.disabledSkills = disabledSkills
        self.enabledToolsets = enabledToolsets
        self.enabledMCPServers = enabledMCPServers
    }

    /// Whether any section is dirty (a no-op edit sends nothing).
    public var isEmpty: Bool {
        metadata == nil && soul == nil && descriptionText == nil
            && model == nil && provider == nil && disabledSkills == nil
            && enabledToolsets == nil && enabledMCPServers == nil
    }

    /// True when a model/provider section is dirty (the confirmation
    /// handshake can apply only to a model write).
    public var hasModelSection: Bool { model != nil || provider != nil }

    /// The confirmation resend shape: ONLY the model section, per upstream
    /// `surfaceModelSwitchConfirm` (a confirm never re-sends other sections).
    public var modelOnlyResend: BotProfileEdit {
        BotProfileEdit(model: model, provider: provider)
    }
}

/// Per-section application outcome from a `profiles.configure` response —
/// the P3 residual this slice closes: the UI shows which keys APPLIED and
/// which FAILED, never a single generic result.
public struct BotProfileEditOutcome: Hashable, Sendable {
    public enum Section: String, Hashable, Sendable, CaseIterable {
        case metadata = "ui_meta"
        case soul = "soul"
        case description = "description"
        case model = "model"
        case skills = "skills"
        case toolsets = "toolsets"
        case mcpServers = "mcp_servers"
    }

    /// Sections the gateway reported applied (from `applied{}` booleans).
    public var appliedSections: Set<Section>
    /// Sections the edit payload carried that the gateway did NOT apply.
    public var failedSections: Set<Section>
    /// New ui_meta revisions on success (`applied.ui_meta_revisions`).
    public var newMetadataRevisions: [String: Int]
    /// CAS conflict detail when the metadata section conflicted.
    public var metadataConflict: MetadataConflict?
    /// Gateway confirmation requirement for a model switch (resend with
    /// `confirm_expensive_model: true` after user consent).
    public var confirmRequired: Bool
    public var confirmMessage: String?

    public struct MetadataConflict: Hashable, Sendable {
        public var expected: Int
        public var actual: Int
        public var key: String

        public init(key: String, expected: Int, actual: Int) {
            self.key = key
            self.expected = expected
            self.actual = actual
        }
    }

    public init(
        appliedSections: Set<Section> = [],
        failedSections: Set<Section> = [],
        newMetadataRevisions: [String: Int] = [:],
        metadataConflict: MetadataConflict? = nil,
        confirmRequired: Bool = false,
        confirmMessage: String? = nil
    ) {
        self.appliedSections = appliedSections
        self.failedSections = failedSections
        self.newMetadataRevisions = newMetadataRevisions
        self.metadataConflict = metadataConflict
        self.confirmRequired = confirmRequired
        self.confirmMessage = confirmMessage
    }

    /// Map an `applied` bool to a section outcome, given which sections the
    /// payload carried (only carried sections can fail — an untouched
    /// section is never written and never reported).
    public init(edit: BotProfileEdit, applied: [String: Bool],
                newMetadataRevisions: [String: Int] = [:],
                metadataConflict: MetadataConflict? = nil,
                confirmRequired: Bool = false, confirmMessage: String? = nil) {
        var appliedSet = Set<Section>()
        var carried = Set<Section>()
        if edit.metadata != nil {
            carried.insert(.metadata)
            if applied["ui_meta"] == true { appliedSet.insert(.metadata) }
        }
        if edit.soul != nil {
            carried.insert(.soul)
            if applied["soul"] == true { appliedSet.insert(.soul) }
        }
        if edit.descriptionText != nil {
            carried.insert(.description)
            if applied["description"] == true { appliedSet.insert(.description) }
        }
        if edit.hasModelSection {
            carried.insert(.model)
            if applied["model"] == true { appliedSet.insert(.model) }
        }
        if edit.disabledSkills != nil {
            carried.insert(.skills)
            if applied["skills"] == true { appliedSet.insert(.skills) }
        }
        if edit.enabledToolsets != nil {
            carried.insert(.toolsets)
            if applied["toolsets"] == true { appliedSet.insert(.toolsets) }
        }
        if edit.enabledMCPServers != nil {
            carried.insert(.mcpServers)
            if applied["mcp_servers"] == true { appliedSet.insert(.mcpServers) }
        }
        self.init(
            appliedSections: appliedSet,
            failedSections: carried.subtracting(appliedSet),
            newMetadataRevisions: newMetadataRevisions,
            metadataConflict: metadataConflict,
            confirmRequired: confirmRequired,
            confirmMessage: confirmMessage
        )
    }

    public var succeeded: Bool { failedSections.isEmpty && !confirmRequired }
}

// MARK: - Duplicate naming

/// Duplicate-name minting with upstream parity: `<base>-2`, `-3`, … first
/// free slot against the occupied set; the BASE is truncated (max 64
/// chars total), never the suffix (profile-ops.ts #19).
public enum BotDuplicateNaming {
    public static func candidateName(
        base: String, occupiedNames: Set<String>, maxLength: Int = 64
    ) -> String? {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }
        for n in 2..<100 {
            let suffix = "-\(n)"
            let candidate = String(trimmedBase.prefix(maxLength - suffix.count)) + suffix
            if !occupiedNames.contains(candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Create spec

/// A `profiles.create` request assembled by the Create Bot sheet.
///
/// Credential semantics copy the upstream wire contract verbatim — the UI
/// renders the gateway's own wording; Fleet adds no new decisions.
public struct BotCreateSpec: Hashable, Sendable {
    public enum Seed: Hashable, Sendable {
        /// Fresh profile; bundled skills are seeded by the gateway.
        case fresh
        /// Clone of an existing profile on the target gateway
        /// (`clone_from`); `cloneAll` selects full-clone vs config-only.
        case clone(profile: String, cloneAll: Bool)
        /// Empty profile with NO skills (`no_skills: true`).
        case emptyNoSkills
    }

    public var name: String
    public var title: String?
    public var descriptionText: String?
    public var seed: Seed
    public var soul: String?
    public var model: String?
    public var provider: String?
    /// `share_auth` (upstream default false).
    public var shareAuth: Bool
    /// `mirror_credentials` (upstream default true).
    public var mirrorCredentials: Bool

    public init(
        name: String,
        title: String? = nil,
        descriptionText: String? = nil,
        seed: Seed = .fresh,
        soul: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        shareAuth: Bool = false,
        mirrorCredentials: Bool = true
    ) {
        self.name = name
        self.title = title
        self.descriptionText = descriptionText
        self.seed = seed
        self.soul = soul
        self.model = model
        self.provider = provider
        self.shareAuth = shareAuth
        self.mirrorCredentials = mirrorCredentials
    }
}

/// Duplicate (clone) confirmation summary: what is inherited vs what is
/// never copied (identity, canonical chat, creation timestamp).
public struct BotDuplicateSummary: Hashable, Sendable {
    public let newProfileName: String
    public let sourceRoute: Route
    /// Inherited per clone mode (config / SOUL / skills / memory / look).
    public let inherited: [String]
    /// Never copied: new profile, own canonical chat, fresh created stamp.
    public let notInherited: [String]

    public init(newProfileName: String, sourceRoute: Route, inherited: [String], notInherited: [String]) {
        self.newProfileName = newProfileName
        self.sourceRoute = sourceRoute
        self.inherited = inherited
        self.notInherited = notInherited
    }

    public static func standard(newProfileName: String, source bot: FleetBot, cloneAll: Bool) -> BotDuplicateSummary {
        BotDuplicateSummary(
            newProfileName: newProfileName,
            sourceRoute: bot.route,
            inherited: cloneAll
                ? ["Configuration", "SOUL", "Skills", "Memory", "Look (shape & color)"]
                : ["Configuration", "SOUL", "Skills", "Look (shape & color)"],
            notInherited: [
                "Identity — a brand-new profile on \(bot.route.gatewayID.rawValue)",
                "Bot Chat — its own forever chat, never a copy",
                "Created date — stamped now",
            ]
        )
    }
}
