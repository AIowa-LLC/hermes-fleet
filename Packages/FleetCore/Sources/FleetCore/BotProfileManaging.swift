import Foundation

/// Seam for Bot Mode profile management — the FleetUI-facing contract for
/// create / edit / duplicate / avatar / sections-registry operations.
///
/// FleetUI depends on this protocol only; the concrete `GatewayBotModeClient`
/// (FleetNetworking) conforms app-side in the composition root, and the
/// DEBUG simulator provides a scripted double (the established
/// `BotModeChatProviding` pattern).
public protocol BotProfileManaging: Sendable {
    func supportsAvatarUpload(_ profile: String) async -> Bool
    func supportsPortraitGeneration() async -> Bool
    func generatePortrait(prompt: String) async throws -> Data

    /// `profiles.describe` — full editable surface for one profile.
    func describeProfile(_ profile: String) async throws -> BotProfileDescription

    /// `profiles.configure` with per-section dirty flags and ui_meta CAS.
    /// A model section may require confirmation — the outcome carries
    /// `confirmRequired`; resend via `configureProfile(edit:confirmExpensiveModel:)`.
    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome

    /// Confirmation resend for a pending model switch (ONLY the model
    /// section — upstream `surfaceModelSwitchConfirm` parity).
    func configureProfile(_ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool) async throws -> BotProfileEditOutcome

    /// `profiles.create` (fresh / clone / empty-no-skills + SOUL/model/
    /// provider/credential semantics). Returns the created profile name.
    @discardableResult
    func createProfile(_ spec: BotCreateSpec) async throws -> String

    /// `profiles.set_asset` avatar upload (data URL; ≤2MB PNG/JPEG/WebP).
    func uploadAvatar(_ profile: String, dataURL: String) async throws

    /// `profiles.set_asset {clear: true}` — remove the avatar asset.
    func clearAvatar(_ profile: String) async throws

    /// `profiles.get_asset` avatar pull → data bytes (nil when absent).
    func avatarData(_ profile: String) async throws -> Data?
}

/// Editable profile surface from `profiles.describe`
/// (methods_profiles.py:400-433).
public struct BotProfileDescription: Hashable, Sendable {
    public struct SkillEntry: Hashable, Sendable {
        public var name: String
        public var enabled: Bool
        public init(name: String, enabled: Bool) {
            self.name = name
            self.enabled = enabled
        }
    }

    public struct ToolsetEntry: Hashable, Sendable {
        public var name: String
        public var label: String?
        public var description: String?
        public var toolCount: Int
        public var enabled: Bool
        public init(name: String, label: String? = nil, description: String? = nil, toolCount: Int = 0, enabled: Bool) {
            self.name = name
            self.label = label
            self.description = description
            self.toolCount = toolCount
            self.enabled = enabled
        }
    }

    public struct MCPEntry: Hashable, Sendable {
        public var name: String
        public var enabled: Bool
        public var transport: String?
        public init(name: String, enabled: Bool, transport: String? = nil) {
            self.name = name
            self.enabled = enabled
            self.transport = transport
        }
    }

    public var name: String
    public var descriptionText: String?
    public var soul: String?
    public var defaultModel: String?
    public var provider: String?
    public var skills: [SkillEntry]
    public var toolsets: [ToolsetEntry]
    public var mcpServers: [MCPEntry]

    public init(
        name: String,
        descriptionText: String? = nil,
        soul: String? = nil,
        defaultModel: String? = nil,
        provider: String? = nil,
        skills: [SkillEntry] = [],
        toolsets: [ToolsetEntry] = [],
        mcpServers: [MCPEntry] = []
    ) {
        self.name = name
        self.descriptionText = descriptionText
        self.soul = soul
        self.defaultModel = defaultModel
        self.provider = provider
        self.skills = skills
        self.toolsets = toolsets
        self.mcpServers = mcpServers
    }

    /// Currently disabled skill names (wire: `disabled_skills`).
    public var disabledSkillNames: [String] {
        skills.filter { !$0.enabled }.map(\.name)
    }

    /// Currently enabled toolset names (wire: `enabled_toolsets`; an empty
    /// list clears the pin).
    public var enabledToolsetNames: [String] {
        toolsets.filter(\.enabled).map(\.name)
    }

    /// Currently enabled MCP server names (wire: `enabled_mcp_servers`).
    public var enabledMCPServerNames: [String] {
        mcpServers.filter(\.enabled).map(\.name)
    }
}

/// Honest delete gating (D12).
///
/// Upstream truth: there is NO `profiles.delete` ws method
/// (methods_profiles.py ends at `register`); deletion exists only via the
/// authenticated dashboard REST router (`hermes_cli/web_routers/profiles.py`
/// → `hermes_cli.profiles.delete_profile`). The Fleet WS transport cannot
/// safely use that surface, so delete is capability-gated OFF by default.
/// When a supported authenticated lifecycle surface arrives upstream, the
/// gate opens with the same typed confirmation contract.
public enum BotDeleteGate: Hashable, Sendable {
    /// Delete is not available on this transport: the dashboard-only
    /// lifecycle surface cannot be driven safely from the WS client.
    case unsupported(reason: String)

    /// Available after explicit user confirmation (typed destructive flow).
    case requiresConfirmation

    /// User-facing explanation for the gated state.
    public var explanation: String {
        switch self {
        case .unsupported(let reason):
            return reason
        case .requiresConfirmation:
            return "Deleting a bot needs the web dashboard."
        }
    }

    /// The single honest default for the current gateway generation.
    public static let currentGatewayGeneration: BotDeleteGate =
        .unsupported(reason: "Bot deletion needs the Hermes web dashboard — the chat connection cannot delete profiles safely.")
}

public extension BotProfileManaging {
    func supportsAvatarUpload(_ profile: String) async -> Bool { false }
    func supportsPortraitGeneration() async -> Bool { false }
    func generatePortrait(prompt: String) async throws -> Data {
        throw BotPortraitError.unavailable
    }
}

public enum BotPortraitError: Error, LocalizedError, Sendable {
    case unavailable
    case invalidImage
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Portrait generation is unavailable on this gateway."
        case .invalidImage: return "The gateway did not return a supported portrait image."
        }
    }
}
