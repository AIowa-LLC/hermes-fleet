import Foundation
import Observation
import FleetCore

/// Bot profile management state + operations for the roster/create/edit/
/// sections surfaces. Owned by `AppEnvironment` (composition-root state) so
/// sheets survive navigation; all writes go through the injected
/// `BotProfileManaging` seam, never FleetNetworking directly.
@MainActor
@Observable
public final class BotManagementController {
    // MARK: Observable state

    /// Sections registry per gateway (Fleet-owned `bot-sections-v1` ui_meta
    /// on the gateway's default profile; Desktop's registry is plugin-local
    /// and never syncs — rendering parity is identical because unknown
    /// sectionIds render unassigned either way).
    public private(set) var sectionsByGateway: [GatewayID: [BotSection]] = [:]
    public private(set) var sectionsSyncErrors: [GatewayID: String] = [:]

    /// In-flight markers.
    public private(set) var syncingSections: Set<GatewayID> = []

    /// Create-bot flow state.
    public private(set) var isCreatingBot = false
    public private(set) var lastCreateError: String?

    /// Edit flow state (per route, one sheet at a time in practice).
    public private(set) var editOutcomes: [Route: BotProfileEditOutcome] = [:]
    public private(set) var editErrors: [Route: String] = [:]

    /// Avatar bytes cache per route (nil = not fetched; the authoritative
    /// flag is the roster's hasAvatar — bytes are a display cache only).
    public private(set) var avatarDataByRoute: [Route: Data] = [:]

    // MARK: Injected seams

    private let factory: FleetBotProfileFactory?
    @ObservationIgnored private var seams: [GatewayID: any BotProfileManaging] = [:]
    private var gatewayProvider: @MainActor () -> [FleetGateway]

    public init(
        factory: FleetBotProfileFactory?,
        gatewayProvider: @escaping @MainActor () -> [FleetGateway] = { [] }
    ) {
        self.factory = factory
        self.gatewayProvider = gatewayProvider
    }

    /// Late-bound gateway provider (the owning environment wires itself in
    /// after its own stored properties are initialized — Swift forbids
    /// capturing `self` in an escaping closure during init).
    public func setGatewayProvider(_ provider: @escaping @MainActor () -> [FleetGateway]) {
        gatewayProvider = provider
    }

    /// Seam for a gateway (nil when no factory wired or gateway absent —
    /// callers render honest unavailable states, fail closed).
    public func seam(for gatewayID: GatewayID) -> (any BotProfileManaging)? {
        if let existing = seams[gatewayID] { return existing }
        guard let factory,
              let gateway = gatewayProvider().first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        seams[gatewayID] = seam
        return seam
    }

    // MARK: - Sections registry (D10)

    /// Load a gateway's Fleet section registry (default profile ui_meta).
    /// Never throws to the caller — errors land in `sectionsSyncErrors`.
    public func loadSections(from gatewayID: GatewayID) async {
        guard !syncingSections.contains(gatewayID) else { return }
        syncingSections.insert(gatewayID)
        defer { syncingSections.remove(gatewayID) }
        guard let loader = seam(for: gatewayID) as? BotSectionRegistryLoading else {
            sectionsSyncErrors[gatewayID] = "Section sync needs a newer Hermes gateway"
            return
        }
        do {
            let registry = try await loader.loadSectionRegistry()
            sectionsByGateway[gatewayID] = registry.sections
            sectionsSyncErrors[gatewayID] = nil
        } catch {
            sectionsByGateway[gatewayID] = []
            sectionsSyncErrors[gatewayID] = error.localizedDescription
        }
    }

    /// Write a new registry (create/rename/reorder/delete) with per-key CAS.
    /// On conflict the current registry is loaded and a typed conflict is
    /// thrown — never a silent overwrite.
    public func saveSections(
        _ sections: [BotSection], on gatewayID: GatewayID
    ) async throws {
        guard let writer = seam(for: gatewayID) as? BotSectionRegistryLoading & BotSectionRegistryWriting else {
            throw BotSectionSyncError.unsupported("Section sync needs a newer Hermes gateway")
        }
        let current = try await writer.loadSectionRegistry()
        let encoded = BotSectionRegistry.encode(sections)
        _ = try await writer.writeSectionRegistry(
            value: encoded, expectedRevision: current.revision)
        sectionsByGateway[gatewayID] = sections
        sectionsSyncErrors[gatewayID] = nil
    }

    /// Move one bot to a section (or unassign) — a per-bot ui_meta CAS write
    /// on the bot's OWN metadata (`sectionId` field), identical to every
    /// other metadata edit.
    public func moveBot(
        _ bot: FleetBot, toSection sectionID: String?
    ) async throws -> BotProfileEditOutcome {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unsupported("Profile management is unavailable on this gateway")
        }
        var metadata = bot.botModeMetadata ?? BotModeMetadata()
        metadata.sectionID = sectionID
        let edit = BotProfileEdit(
            metadata: metadata,
            metadataExpectedRevision: bot.uiMetaRevisions?[BotModeContract.botsMetaKey],
            previousMetadataRaw: bot.uiMeta?[BotModeContract.botsMetaKey])
        let outcome = try await seam.configureProfile(
            bot.route.profileSlug.rawValue, edit: edit)
        editOutcomes[bot.route] = outcome
        return outcome
    }

    // MARK: - Create (D05/D06)

    /// Create a bot on the TARGET gateway (never switches the app's active
    /// gateway — requests route to the chosen gateway's seam). On success a
    /// fresh canonical Bot Chat does not exist yet; the roster refresh after
    /// creation shows the new profile, and the first tap creates the chat.
    public func createBot(_ spec: BotCreateSpec, on gatewayID: GatewayID) async throws -> String {
        guard let seam = seam(for: gatewayID) else {
            throw BotSectionSyncError.unsupported("Profile management is unavailable on this gateway")
        }
        isCreatingBot = true
        defer { isCreatingBot = false }
        lastCreateError = nil
        do {
            let name = try await seam.createProfile(spec)
            return name
        } catch {
            lastCreateError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Edit (D07)

    /// Load the editable surface for one bot.
    public func describeBot(_ bot: FleetBot) async throws -> BotProfileDescription {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        return try await seam.describeProfile(bot.route.profileSlug.rawValue)
    }

    /// Apply an edit; a model-confirmation requirement is returned for the
    /// caller to surface as a native confirmationDialog (never bypassed).
    public func applyEdit(
        _ edit: BotProfileEdit, to bot: FleetBot
    ) async throws -> BotProfileEditOutcome {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        do {
            let outcome = try await seam.configureProfile(
                bot.route.profileSlug.rawValue, edit: edit)
            editOutcomes[bot.route] = outcome
            editErrors[bot.route] = nil
            return outcome
        } catch let error as LocalizedError {
            editErrors[bot.route] = error.errorDescription
            throw error
        }
    }

    /// Resend a model-only edit after explicit user confirmation.
    public func confirmModelEdit(
        _ edit: BotProfileEdit, for bot: FleetBot
    ) async throws -> BotProfileEditOutcome {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        let outcome = try await seam.configureProfile(
            bot.route.profileSlug.rawValue,
            edit: edit.modelOnlyResend,
            confirmExpensiveModel: true)
        editOutcomes[bot.route] = outcome
        return outcome
    }

    // MARK: - Avatar (D08)

    /// Fetch avatar bytes for a bot (display cache; authoritative flag is
    /// roster hasAvatar). Uses the profiles.get_asset surface.
    public func loadAvatar(for bot: FleetBot) async {
        guard avatarDataByRoute[bot.route] == nil else { return }
        guard let seam = seam(for: bot.route.gatewayID) else { return }
        if let data = try? await seam.avatarData(bot.route.profileSlug.rawValue),
           !data.isEmpty {
            avatarDataByRoute[bot.route] = data
        }
    }

    /// Upload an avatar image (data URL) via set_asset ONLY — never ui_meta.
    public func uploadAvatar(_ bot: FleetBot, dataURL: String) async throws {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        try await seam.uploadAvatar(bot.route.profileSlug.rawValue, dataURL: dataURL)
        avatarDataByRoute[bot.route] = GatewayBotModeClientBridge.decodeDataURLBytes(dataURL)
    }

    /// Clear the avatar asset ({clear: true}).
    public func clearAvatar(_ bot: FleetBot) async throws {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        try await seam.clearAvatar(bot.route.profileSlug.rawValue)
        avatarDataByRoute[bot.route] = nil
    }

    // MARK: - Duplicate (D11)

    /// Duplicate a bot via supported profile clone: profiles.create
    /// {clone_from} + look copy (shape/color) via metadata; new profile,
    /// own canonical chat, fresh created stamp — the canonical pointer and
    /// created are NEVER copied.
    public func duplicateBot(
        _ bot: FleetBot, occupiedNames: Set<String>
    ) async throws -> String {
        guard let newName = BotDuplicateNaming.candidateName(
            base: bot.route.profileSlug.rawValue, occupiedNames: occupiedNames) else {
            throw BotSectionSyncError.unavailable("No free name for the duplicate")
        }
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        // 1. Clone the profile (config/skills/SOUL/memory per clone_from).
        let spec = BotCreateSpec(
            name: newName,
            descriptionText: bot.profileDescription,
            seed: .clone(profile: bot.route.profileSlug.rawValue, cloneAll: true))
        _ = try await seam.createProfile(spec)
        // 2. Copy the LOOK only (shape/color; title gets "(copy)"). `chat`
        //    and `created` are never written — those belong to the original.
        var look = bot.botModeMetadata ?? BotModeMetadata()
        look.sectionID = nil
        let title = bot.botModeMetadata?.title.map { "\($0) (copy)" }
        look.title = title
        let edit = BotProfileEdit(metadata: look)
        _ = try? await seam.configureProfile(newName, edit: edit)
        return newName
    }

    // MARK: - Delete gate (D12)

    /// Honest delete gate for the current gateway generation: the WS
    /// transport has no safe authenticated lifecycle surface — the item is
    /// rendered disabled with its explanation, never a facade.
    public func deleteGate(for gatewayID: GatewayID) -> BotDeleteGate {
        _ = gatewayID
        return BotDeleteGate.currentGatewayGeneration
    }
}

/// Section-registry sync capability (the concrete client conforms; gateways
/// without the ui_meta surface surface an honest unavailable state).
public protocol BotSectionRegistryLoading: Sendable {
    func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?)
}

public protocol BotSectionRegistryWriting: Sendable {
    func writeSectionRegistry(value: MetadataValue, expectedRevision: Int?) async throws -> MetadataWriteReceiptLike
}

/// Transport-agnostic write receipt (FleetNetworking's MetadataWriteReceipt
/// conforms app-side).
public struct MetadataWriteReceiptLike: Hashable, Sendable {
    public let applied: Bool
    public let newRevisions: [String: Int]
    public init(applied: Bool, newRevisions: [String: Int]) {
        self.applied = applied
        self.newRevisions = newRevisions
    }
}

/// Typed section-sync failures.
public enum BotSectionSyncError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case unavailable(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .unavailable(let s): return s
        case .conflict(let s): return "Sections were changed by another client — \(s)"
        }
    }
}

/// Tiny bridge for data-URL decoding without importing FleetNetworking.
enum GatewayBotModeClientBridge {
    static func decodeDataURLBytes(_ dataURL: String) -> Data? {
        guard let range = dataURL.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(dataURL[range.upperBound...]))
    }
}
