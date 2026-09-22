import Foundation
import FleetCore

/// Hermes command client over the conversation gateway transport.
///
/// This client intentionally delegates discovery, ranking, collision
/// precedence, and command expansion to Hermes. Fleet adds only the iOS
/// disposition layer on top of the authoritative backend metadata.
public struct GatewaySlashCommandClient: SlashCommandProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: SlashCommandProviding

    public func catalog(sessionID: String?) async throws -> HermesCommandCatalog {
        var params: [String: JSONValue] = [:]
        if let sessionID {
            guard RoutingGuard.isValidSessionKey(sessionID) else {
                throw SlashCommandError.invalidRequest("session_id is not a safe session key")
            }
            params["session_id"] = .string(sessionID)
        }
        let result = try await request(method: "commands.catalog", params: .object(params))
        return try Self.decodeCatalog(result)
    }

    public func complete(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] {
        guard text.hasPrefix("/") else { return [] }
        // Wire-verified against hermes-agent 0.21.3: complete.slash's params
        // model accepts ONLY {text} — a session_id key is rejected with
        // "Extra inputs are not permitted". The seam keeps the sessionID
        // parameter for caller symmetry; it is not sent on this method.
        let result = try await request(
            method: "complete.slash",
            params: .object(["text": .string(text)]))
        return try Self.decodeCompletions(result)
    }

    public func dispatch(sessionID: String, name: String, argument: String) async throws -> HermesCommandDispatch {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SlashCommandError.invalidRequest("session_id is not a safe session key")
        }
        let normalizedName = try Self.normalizedCommandName(name)
        let result = try await request(
            method: "command.dispatch",
            params: .object([
                "session_id": .string(sessionID),
                "name": .string(normalizedName),
                "arg": .string(argument),
            ]))
        return try Self.decodeDispatch(result)
    }

    public func execute(sessionID: String, command: String) async throws -> HermesSlashExecution {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SlashCommandError.invalidRequest("session_id is not a safe session key")
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else {
            throw SlashCommandError.invalidRequest("command must be a slash-prefixed invocation")
        }
        // slash.exec takes the command WITHOUT the leading slash (Desktop:
        // `command.replace(/^\/+/, '')`). The strip is a `drop(while:)` over
        // EVERY leading slash, so the slash-prefixed guard above cannot vouch
        // for the payload: `//` / `///` strip to an empty command. Validate
        // the STRIPPED form before it can be sent.
        let bare = String(trimmed.drop(while: { $0 == "/" }))
        guard !bare.isEmpty else {
            throw SlashCommandError.invalidRequest("command must name a command after the slash")
        }
        let result = try await request(
            method: "slash.exec",
            params: .object([
                "session_id": .string(sessionID),
                "command": .string(bare),
            ]))
        return try Self.decodeExecution(result)
    }

    public func stopProcesses(sessionID: String) async throws -> Int {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SlashCommandError.invalidRequest("session_id is not a safe session key")
        }
        let result = try await request(
            method: "process.stop",
            params: .object(["session_id": .string(sessionID)]))
        guard let object = result.objectValue,
              let killed = Self.intValue(object["killed"]) else {
            throw SlashCommandError.malformedResponse("process.stop result missing 'killed'")
        }
        return killed
    }

    // MARK: Catalog decoding

    /// Decode `commands.catalog` into the full Hermes command surface.
    ///
    /// Wire shape (hermes-agent 0.21.3, tui_gateway/methods_tools.py `_Catalog`):
    /// - `pairs`: every `[key, desc]` row in backend order — registry commands
    ///   (canonical only), then quick commands, plugin commands, and skills.
    /// - `canon`: lowercased key/alias → canonical key (aliases included).
    /// - `commands`: `/name` → `{argument_mode, desktop}` for every registry
    ///   command AND alias.
    /// - `categories`: ordered `{name, pairs}` sections (Fleet renders its own
    ///   Commands/Skills grouping, so this is not separately modeled).
    /// - `skills`: skill token → `{usage, origin}`.
    /// - `warning`: discovery warning string.
    static func decodeCatalog(_ result: JSONValue) throws -> HermesCommandCatalog {
        guard let object = result.objectValue else {
            throw SlashCommandError.malformedResponse("commands.catalog result is not an object")
        }
        guard let pairs = object["pairs"]?.arrayValue else {
            throw SlashCommandError.malformedResponse("commands.catalog result missing 'pairs'")
        }

        // canon: lowercased token → canonical token.
        var canon: [String: String] = [:]
        if let canonObject = object["canon"]?.objectValue {
            for (key, value) in canonObject {
                if let canonical = value.stringValue {
                    canon[key.lowercased()] = canonical
                }
            }
        }

        // commandMeta: `/name` → {argument_mode, desktop} (registry + aliases).
        var argumentModes: [String: String] = [:]
        var desktopDispositions: [String: String] = [:]
        if let commandsObject = object["commands"]?.objectValue {
            for (key, value) in commandsObject {
                guard let meta = value.objectValue else { continue }
                let lowered = key.lowercased()
                if let mode = meta["argument_mode"]?.stringValue {
                    argumentModes[lowered] = mode
                }
                if let desktop = meta["desktop"]?.stringValue {
                    desktopDispositions[lowered] = desktop
                }
            }
        }

        // skills map: token → {usage, origin}.
        var skillEntries: [String: HermesCommandCatalog.SkillEntry] = [:]
        var skillUsage: [String: Int] = [:]
        if let skillsObject = object["skills"]?.objectValue {
            for (key, value) in skillsObject {
                guard let entry = value.objectValue else { continue }
                let usage = Self.intValue(entry["usage"]) ?? 0
                let origin = entry["origin"]?.stringValue ?? "local"
                skillEntries[key] = HermesCommandCatalog.SkillEntry(usage: usage, origin: origin)
                skillUsage[key.lowercased()] = usage
            }
        }

        // Rows: backend order from `pairs`. A pair whose key is a canon ALIAS
        // of a different canonical does not appear (the gateway emits canonical
        // pairs only), but a defensive alias check keeps a future shape honest
        // without dropping the row.
        var commands: [SlashCommandSuggestion] = []
        for pair in pairs {
            guard case .array(let fields) = pair,
                  let rawCommand = fields.first?.stringValue,
                  let token = Self.normalizedSlashToken(rawCommand) else {
                // A future non-command catalog row must not poison the whole
                // list. It cannot be selected safely, so skip it.
                continue
            }
            let key = token.lowercased()
            let description = fields.dropFirst().first?.stringValue ?? ""
            let canonicalKey = canon[key]
            let isAlias = canonicalKey != nil && canonicalKey!.lowercased() != key
            let argumentMode = argumentModes[key].flatMap(SlashCommandSuggestion.ArgumentMode.init(rawValue:))
            let desktop = desktopDispositions[key]
            let isSkill = skillEntries[token] != nil || skillEntries[key] != nil
            let kind: SlashCommandSuggestion.Kind
            if isSkill {
                kind = .skill
            } else if argumentModes[key] != nil || desktop != nil {
                // Present in the registry `commands` map → a Hermes built-in.
                kind = .command
            } else {
                // Quick commands / plugin commands: user-activated extensions.
                kind = .extensionCommand
            }
            commands.append(SlashCommandSuggestion(
                text: token,
                display: token,
                description: description,
                kind: kind,
                argumentMode: argumentMode,
                canonical: isAlias ? canonicalKey : nil,
                desktopDisposition: desktop,
                usage: skillUsage[key] ?? 0))
        }

        let warning = object["warning"]?.stringValue
        let warningValue = (warning?.isEmpty == false) ? warning : nil

        // commandMeta: `/name` → argument mode + desktop disposition, for
        // every registry command AND alias (the wire `commands` map carries
        // aliases too). `complete.slash` rows carry NO disposition, so
        // `ConversationViewModel.row(_:enrichedWith:)` reads them from HERE —
        // an empty map silently no-ops that enrichment on every real gateway
        // (the simulator populated it, which is why only network clients were
        // affected).
        var commandMeta: [String: SlashCommandSuggestion] = [:]
        for key in Set(argumentModes.keys).union(desktopDispositions.keys) {
            let canonicalKey = canon[key]
            let isAlias = canonicalKey.map { $0.lowercased() != key } ?? false
            commandMeta[key] = SlashCommandSuggestion(
                text: key,
                kind: .command,
                argumentMode: argumentModes[key].flatMap(SlashCommandSuggestion.ArgumentMode.init(rawValue:)),
                canonical: isAlias ? canonicalKey : nil,
                desktopDisposition: desktopDispositions[key])
        }

        return HermesCommandCatalog(
            commands: commands,
            canon: canon,
            commandMeta: commandMeta,
            skills: skillEntries,
            warning: warningValue)
    }

    // MARK: Completion decoding

    /// Decode `complete.slash` items. Each row carries backend `kind`
    /// ("command" or "skill"); ordering is the backend's ranking and is
    /// preserved exactly.
    static func decodeCompletions(_ result: JSONValue) throws -> [SlashCommandSuggestion] {
        guard let items = result["items"]?.arrayValue else {
            throw SlashCommandError.malformedResponse("complete.slash result missing 'items'")
        }
        return items.compactMap { item in
            guard let object = item.objectValue,
                  let rawText = object["text"]?.stringValue,
                  let text = Self.normalizedSlashToken(rawText) else { return nil }
            let display = object["display"]?.stringValue?.isEmpty == false
                ? object["display"]!.stringValue!
                : text
            let description = object["meta"]?.stringValue ?? ""
            let rawKind = object["kind"]?.stringValue?.lowercased()
            let kind: SlashCommandSuggestion.Kind
            switch rawKind {
            case "skill": kind = .skill
            case "command": kind = .command
            default: kind = .unknown
            }
            return SlashCommandSuggestion(
                text: text,
                display: display,
                description: description,
                kind: kind)
        }
    }

    // MARK: Dispatch decoding

    /// Decode `command.dispatch` (and the structured form of `slash.exec`).
    /// Mirrors `apps/shared/src/slash.ts::parseCommandDispatch`: each type has
    /// one required field; anything else fails closed as malformed/unknown.
    static func decodeDispatch(_ result: JSONValue) throws -> HermesCommandDispatch {
        guard let object = result.objectValue else {
            throw SlashCommandError.malformedResponse("command.dispatch result is not an object")
        }
        guard let type = object["type"]?.stringValue else {
            throw SlashCommandError.malformedResponse("command.dispatch result missing 'type'")
        }
        switch type.lowercased() {
        case "exec":
            return .exec(output: object["output"]?.stringValue, warning: nil)
        case "plugin":
            return .plugin(output: object["output"]?.stringValue)
        case "alias":
            guard let target = object["target"]?.stringValue,
                  !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SlashCommandError.malformedResponse("alias dispatch result missing 'target'")
            }
            return .alias(target: target)
        case "send":
            guard let message = object["message"]?.stringValue else {
                throw SlashCommandError.malformedResponse("send dispatch result missing 'message'")
            }
            return .send(
                message: message,
                display: object["display"]?.stringValue,
                notice: object["notice"]?.stringValue)
        case "skill":
            guard let message = object["message"]?.stringValue,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SlashCommandError.malformedResponse("skill dispatch result missing non-empty 'message'")
            }
            return .skill(
                message: message,
                display: object["display"]?.stringValue)
        case "prefill":
            guard let message = object["message"]?.stringValue else {
                throw SlashCommandError.malformedResponse("prefill dispatch result missing 'message'")
            }
            return .prefill(
                message: message,
                notice: object["notice"]?.stringValue)
        default:
            // Unknown future type: fail closed, never reinterpret as chat.
            throw SlashCommandError.unknownDispatchType(type)
        }
    }

    /// Decode `slash.exec`: either plain worker output (`output` + optional
    /// `warning`) or — when the command rerouted to command.dispatch — the
    /// structured dispatch shape (signalled by a non-null `type`).
    static func decodeExecution(_ result: JSONValue) throws -> HermesSlashExecution {
        guard let object = result.objectValue else {
            throw SlashCommandError.malformedResponse("slash.exec result is not an object")
        }
        if let type = object["type"]?.stringValue, !type.isEmpty {
            let dispatch = try Self.decodeDispatch(result)
            return HermesSlashExecution(output: nil, warning: nil, dispatch: dispatch)
        }
        return HermesSlashExecution(
            output: object["output"]?.stringValue,
            warning: object["warning"]?.stringValue,
            dispatch: nil)
    }

    // MARK: Name normalization

    static func normalizedCommandName(_ name: String) throws -> String {
        let rawName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = rawName.hasPrefix("/")
            ? String(rawName.dropFirst())
            : rawName
        guard !normalizedName.isEmpty,
              RoutingGuard.isValidRouteComponent(normalizedName) else {
            throw SlashCommandError.invalidRequest("command name is not a safe token")
        }
        return normalizedName
    }

    static func normalizedSlashToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard token.hasPrefix("/"), token.count > 1 else { return nil }
        let name = String(token.dropFirst())
        guard RoutingGuard.isValidRouteComponent(name) else { return nil }
        return "/\(name)"
    }

    /// `JSONValue` stores numbers as Double; usage counts are small integers.
    ///
    /// The upper bound is 2^63 EXCLUSIVE, not `Double(Int.max)`: that value
    /// rounds UP to exactly 2^63, so `n <= Double(Int.max)` admits 2^63 and
    /// `Int(2^63)` traps. Every representable `n` below 2^63 converts without
    /// trapping (Int truncates the fraction).
    static func intValue(_ value: JSONValue?) -> Int? {
        guard case .number(let n)? = value else { return nil }
        guard n.isFinite, n >= 0, n < 9_223_372_036_854_775_808.0 else { return nil }
        return Int(n)
    }

    // MARK: Request/error mapping

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard case .connected = transport.state else {
            throw SlashCommandError.rpcFailed("gateway not connected")
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as SlashCommandError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error, method: method)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw SlashCommandError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    static func mapRPCError(_ error: JSONRPCError, method: String) -> SlashCommandError {
        if error.code == -32601 {
            return .unsupportedCapability(method: method)
        }
        return .rpcFailed("\(Redaction.safeText(error.message)) (\(error.code))")
    }

    static func mapTransportError(_ error: TransportError) -> SlashCommandError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let detail):
            return .rpcFailed("invalid state: \(detail)")
        default:
            return .rpcFailed(Redaction.safeErrorDescription(error))
        }
    }
}
