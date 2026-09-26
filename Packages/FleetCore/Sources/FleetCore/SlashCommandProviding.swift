import Foundation

// MARK: - Suggestions

/// One Hermes slash-command row: a built-in, a user quick command, a plugin
/// command, or an installed skill. The gateway's live catalog/completer is the
/// source of truth; FleetCore models only what the iOS composer needs and
/// never infers kind from names, icons, or local files.
public struct SlashCommandSuggestion: Identifiable, Equatable, Sendable {
    /// How Hermes classified the row. Backend-provided labels are trusted;
    /// `extensionCommand` covers user quick commands and plugin commands,
    /// which stay executable without a Fleet release.
    public enum Kind: String, Equatable, Sendable {
        case command
        case skill
        case extensionCommand
        case unknown
    }

    /// Canonical slash token, for example `/steer` or `/hermes-change-review`.
    public let text: String
    /// Human-facing label supplied by the gateway.
    public let display: String
    /// Human-facing description supplied by the gateway catalog/completer.
    public let description: String
    /// Backend-provided result kind.
    public let kind: Kind
    /// Upstream `argument_mode` (`options`/`text`/`mixed`) when known.
    public let argumentMode: ArgumentMode?
    /// Canonical token when `text` is an alias, else nil. Aliases stay
    /// executable when typed manually but are not offered as duplicate rows.
    public let canonical: String?
    /// Upstream `desktop` disposition (`terminal`/`messaging`/`settings`/
    /// `advanced`/`composer-voice`/`hidden`) when the catalog carries it.
    public let desktopDisposition: String?
    /// Live skill usage count from the catalog's `skills` map (0 for
    /// commands), used for browsing-rank only — never to hide a query match.
    public let usage: Int

    public enum ArgumentMode: String, Equatable, Sendable {
        case options
        case text
        case mixed
    }

    public init(
        text: String,
        display: String? = nil,
        description: String = "",
        kind: Kind = .skill,
        argumentMode: ArgumentMode? = nil,
        canonical: String? = nil,
        desktopDisposition: String? = nil,
        usage: Int = 0
    ) {
        self.text = text
        self.display = display ?? text
        self.description = description
        self.kind = kind
        self.argumentMode = argumentMode
        self.canonical = canonical
        self.desktopDisposition = desktopDisposition
        self.usage = usage
    }

    public var id: String { text }
}

// MARK: - Catalog

/// `commands.catalog` — the full Hermes command surface (registry built-ins,
/// user quick commands, plugin commands, and installed skills), preserved in
/// backend order with aliases, argument modes, and disposition metadata.
public struct HermesCommandCatalog: Equatable, Sendable {
    /// Ordered rows (built-ins, quick commands, plugin commands first — the
    /// gateway's `pairs` order — then skills) with descriptions attached.
    public let commands: [SlashCommandSuggestion]
    /// Lowercased alias/canonical token → canonical token (e.g. `/reset` →
    /// `/new`). Only canonical rows appear in `commands`.
    public let canon: [String: String]
    /// `/name` → argument mode + desktop disposition, for every registry
    /// command AND alias (the wire shape `commands` map carries aliases too).
    public let commandMeta: [String: SlashCommandSuggestion]
    /// Live skill provenance: skill token → (usage, origin).
    public let skills: [String: HermesCommandCatalog.SkillEntry]
    /// Backend discovery warning (quick-command/plugin scan failures), if any.
    public let warning: String?

    public struct SkillEntry: Equatable, Sendable {
        public let usage: Int
        public let origin: String

        public init(usage: Int, origin: String) {
            self.usage = usage
            self.origin = origin
        }
    }

    public init(
        commands: [SlashCommandSuggestion],
        canon: [String: String],
        commandMeta: [String: SlashCommandSuggestion],
        skills: [String: SkillEntry],
        warning: String? = nil
    ) {
        self.commands = commands
        self.canon = canon
        self.commandMeta = commandMeta
        self.skills = skills
        self.warning = warning
    }

    /// Resolve a typed token (alias or canonical) to its canonical form.
    public func canonicalForm(of token: String) -> String {
        let key = token.lowercased()
        return canon[key] ?? key
    }
}

// MARK: - Dispatch

/// One structured `command.dispatch` / `slash.exec` directive. Wire shapes
/// verified against hermes-agent 0.21.3 `tui_gateway/contracts/tools_commands.py`
/// (`CommandDispatchResult`): `exec`/`plugin` carry `output`; `alias` a
/// `target`; `send`/`prefill`/`skill` a `message` (UIs render `display`,
/// never `message`); `notice` rides on send/prefill.
public enum HermesCommandDispatch: Equatable, Sendable {
    case exec(output: String?, warning: String?)
    case alias(target: String)
    case plugin(output: String?)
    case send(message: String, display: String?, notice: String?)
    case skill(message: String, display: String?)
    case prefill(message: String, notice: String?)
}

/// `slash.exec` result: either plain worker output (`output`, optional
/// `warning`) or the same structured dispatch shape as `command.dispatch`
/// (signalled by a non-nil `type`).
public struct HermesSlashExecution: Equatable, Sendable {
    public let output: String?
    public let warning: String?
    public let dispatch: HermesCommandDispatch?

    public init(output: String?, warning: String? = nil, dispatch: HermesCommandDispatch? = nil) {
        self.output = output
        self.warning = warning
        self.dispatch = dispatch
    }
}

// MARK: - Errors

/// Typed failures for the optional slash-command surface.
public enum SlashCommandError: Error, Sendable, Equatable, LocalizedError {
    /// One or more slash RPCs are unavailable on an older gateway.
    case unsupportedCapability(method: String)
    /// The gateway returned a response that cannot safely drive the picker or
    /// dispatch path.
    case malformedResponse(String)
    /// Dispatch resolved to a command Fleet can no longer confirm is
    /// available. Stale-discovery guard: must never be submitted as chat.
    case commandUnavailable(String)
    /// The gateway returned a dispatch type this Fleet version does not
    /// understand. Fail closed; never reinterpret as ordinary chat.
    case unknownDispatchType(String)
    /// The caller supplied an unsafe/empty command name or session id.
    case invalidRequest(String)
    /// A transport or gateway RPC failure.
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCapability(let method):
            return "This gateway does not support Hermes commands (\(method))."
        case .malformedResponse(let detail):
            return "Malformed Hermes command response: \(detail)"
        case .commandUnavailable(let name):
            return "/\(name) is no longer available. Refresh the list and try again."
        case .unknownDispatchType(let type):
            return "This Hermes command returned a response this version of Fleet does not understand (type \(type))."
        case .invalidRequest(let detail):
            return "Invalid Hermes command request: \(detail)"
        case .rpcFailed(let detail):
            return "Hermes command request failed: \(detail)"
        }
    }
}

// MARK: - Seam

/// FleetCore seam for Hermes' canonical command protocol:
/// `commands.catalog`, `complete.slash`, `command.dispatch`, `slash.exec`.
///
/// Discovery and completion return the full command surface; Fleet's iOS
/// disposition layer (FleetCommandSurface) decides how a row is fulfilled,
/// never whether it exists.
public protocol SlashCommandProviding: Sendable {
    /// The active gateway's full Hermes command catalog. `sessionID` is
    /// optional because a fresh composer can open before a runtime session
    /// exists.
    func catalog(sessionID: String?) async throws -> HermesCommandCatalog

    /// Complete a slash token through Hermes' live completer. The text is the
    /// exact slash-prefixed composer text being completed. Returns command AND
    /// skill/extension rows; ordering is the backend's ranking.
    func complete(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion]

    /// Resolve a command (canonical name or alias, leading slash optional)
    /// into a structured dispatch directive.
    func dispatch(sessionID: String, name: String, argument: String) async throws -> HermesCommandDispatch

    /// Run a full `/name arg` command against the session's slash worker.
    /// Plain output models a worker/plugin reply; a structured dispatch models
    /// the rerouted case (non-nil `type` on the wire).
    func execute(sessionID: String, command: String) async throws -> HermesSlashExecution

    /// `process.stop` — kill every background process owned by the session's
    /// profile, answering the count killed (the `/stop` cleanup half). The
    /// smallest typed capability for backend process cleanup; older gateways
    /// answer -32601 and Fleet degrades honestly.
    func stopProcesses(sessionID: String) async throws -> Int
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

    public func catalog(sessionID: String?) async throws -> HermesCommandCatalog {
        throw SlashCommandError.unsupportedCapability(method: "commands.catalog")
    }

    public func complete(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] {
        throw SlashCommandError.unsupportedCapability(method: "complete.slash")
    }

    public func dispatch(sessionID: String, name: String, argument: String) async throws -> HermesCommandDispatch {
        throw SlashCommandError.unsupportedCapability(method: "command.dispatch")
    }

    public func execute(sessionID: String, command: String) async throws -> HermesSlashExecution {
        throw SlashCommandError.unsupportedCapability(method: "slash.exec")
    }

    public func stopProcesses(sessionID: String) async throws -> Int {
        throw SlashCommandError.unsupportedCapability(method: "process.stop")
    }
}
