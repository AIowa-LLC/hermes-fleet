import Foundation

/// A skill-backed slash completion returned by the active Hermes gateway.
///
/// The gateway is the source of truth for this list. FleetCore deliberately
/// models only the skill subset used by the conversation composer; it does not
/// own a registry or infer skill commands from names or local files.
public struct SlashCommandSuggestion: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case skill
    }

    /// Canonical slash token, for example `/hermes-change-review`.
    public let text: String
    /// Human-facing label supplied by the gateway.
    public let display: String
    /// Human-facing description supplied by the gateway catalog/completer.
    public let description: String
    /// Backend-provided result kind. V1 exposes skills only.
    public let kind: Kind

    public init(
        text: String,
        display: String? = nil,
        description: String = "",
        kind: Kind = .skill
    ) {
        self.text = text
        self.display = display ?? text
        self.description = description
        self.kind = kind
    }

    public var id: String { text }
}

/// The two representations Hermes returns for a dispatched skill.
/// `message` is expanded model-facing scaffolding; `display` is the compact
/// human-facing slash invocation that belongs in the transcript.
public struct SkillCommandDispatch: Equatable, Sendable {
    public let name: String
    public let message: String
    public let display: String

    public init(name: String, message: String, display: String) {
        self.name = name
        self.message = message
        self.display = display
    }
}

/// Typed failures for the optional slash-command surface.
public enum SlashCommandError: Error, Sendable, Equatable, LocalizedError {
    /// One or more slash RPCs are unavailable on an older gateway.
    case unsupportedCapability(method: String)
    /// The gateway returned a response that cannot safely drive the picker or
    /// dispatch path.
    case malformedResponse(String)
    /// Dispatch resolved to a command that is not a skill. This is a stale
    /// discovery guard: it must never be submitted as ordinary chat.
    case notSkillCommand(String)
    /// The caller supplied an unsafe/empty skill name or session id.
    case invalidRequest(String)
    /// A transport or gateway RPC failure.
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCapability(let method):
            return "This gateway does not support skill commands (\(method))."
        case .malformedResponse(let detail):
            return "Malformed skill command response: \(detail)"
        case .notSkillCommand(let name):
            return "/\(name) is no longer an available skill. Refresh the list and try again."
        case .invalidRequest(let detail):
            return "Invalid skill command request: \(detail)"
        case .rpcFailed(let detail):
            return "Skill command request failed: \(detail)"
        }
    }
}

/// FleetCore seam for Hermes' canonical slash protocol:
/// `commands.catalog`, `complete.slash`, and `command.dispatch`.
public protocol SlashCommandProviding: Sendable {
    /// Discover the active gateway's skill commands. `sessionID` is optional
    /// because a fresh composer can open before a runtime session exists.
    func skillCatalog(sessionID: String?) async throws -> [SlashCommandSuggestion]

    /// Complete a slash token through Hermes' live completer. The text is the
    /// exact slash-prefixed composer text being completed.
    func completeSkills(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion]

    /// Resolve a skill into its model-facing expanded message and its compact
    /// transcript display projection.
    func dispatchSkill(sessionID: String, name: String, argument: String) async throws -> SkillCommandDispatch
}

/// Capability marker used by the composition root. Keeping this separate
/// from `ConversationSessionProviding` preserves fail-closed compatibility
/// with older gateways and scripted/preview sessions.
public protocol SlashCommandCapable: ConversationSessionProviding {
    var slashCommands: any SlashCommandProviding { get }
}

/// Fail-closed implementation for sessions that do not expose Hermes' slash
/// protocol. Ordinary conversation remains usable through its own seam.
public struct UnsupportedSlashCommandProviding: SlashCommandProviding {
    public init() {}

    public func skillCatalog(sessionID: String?) async throws -> [SlashCommandSuggestion] {
        throw SlashCommandError.unsupportedCapability(method: "commands.catalog")
    }

    public func completeSkills(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] {
        throw SlashCommandError.unsupportedCapability(method: "complete.slash")
    }

    public func dispatchSkill(sessionID: String, name: String, argument: String) async throws -> SkillCommandDispatch {
        throw SlashCommandError.unsupportedCapability(method: "command.dispatch")
    }
}
