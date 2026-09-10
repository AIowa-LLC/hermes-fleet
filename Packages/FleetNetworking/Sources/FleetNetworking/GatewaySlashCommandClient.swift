import Foundation
import FleetCore

/// Hermes slash-command client over the conversation gateway transport.
///
/// This client intentionally delegates discovery, ranking, collision
/// precedence, and skill expansion to Hermes. Fleet only filters the
/// authoritative backend metadata to the skill results that the composer can
/// safely offer.
public struct GatewaySlashCommandClient: SlashCommandProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: SlashCommandProviding

    public func skillCatalog(sessionID: String?) async throws -> [SlashCommandSuggestion] {
        var params: [String: JSONValue] = [:]
        if let sessionID {
            guard RoutingGuard.isValidSessionKey(sessionID) else {
                throw SlashCommandError.invalidRequest("session_id is not a safe session key")
            }
            params["session_id"] = .string(sessionID)
        }
        let result = try await request(method: "commands.catalog", params: .object(params))
        return try Self.decodeSkillCatalog(result)
    }

    public func completeSkills(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] {
        guard text.hasPrefix("/") else { return [] }
        // Hermes labels both ordinary skills and skill bundles as `kind:
        // "skill"`. The catalog's collision-safe `skills` map is the
        // authoritative distinction for Fleet's skills-only picker, so load
        // it before accepting typed completion rows. Filtering below keeps
        // the order/ranking returned by complete.slash.
        let catalog = try await skillCatalog(sessionID: sessionID)
        let authoritativeSkills = Set(catalog.map { $0.text.lowercased() })
        var params: [String: JSONValue] = ["text": .string(text)]
        if let sessionID {
            guard RoutingGuard.isValidSessionKey(sessionID) else {
                throw SlashCommandError.invalidRequest("session_id is not a safe session key")
            }
            params["session_id"] = .string(sessionID)
        }
        let result = try await request(method: "complete.slash", params: .object(params))
        return try Self.decodeSkillCompletions(result)
            .filter { authoritativeSkills.contains($0.text.lowercased()) }
    }

    public func dispatchSkill(sessionID: String, name: String, argument: String) async throws -> SkillCommandDispatch {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SlashCommandError.invalidRequest("session_id is not a safe session key")
        }
        let rawName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = rawName.hasPrefix("/")
            ? String(rawName.dropFirst())
            : rawName
        guard !normalizedName.isEmpty,
              RoutingGuard.isValidRouteComponent(normalizedName) else {
            throw SlashCommandError.invalidRequest("skill name is not a safe command token")
        }
        let result = try await request(
            method: "command.dispatch",
            params: .object([
                "session_id": .string(sessionID),
                "name": .string(normalizedName),
                "arg": .string(argument),
            ]))
        return try Self.decodeSkillDispatch(
            result,
            requestedName: normalizedName,
            argument: argument)
    }

    // MARK: Wire decoding

    /// Decode `commands.catalog` using `skills` as the authoritative set and
    /// `pairs` only as the description join. A skill is not offered when a
    /// registry/plugin/quick command occupies the same slash namespace.
    static func decodeSkillCatalog(_ result: JSONValue) throws -> [SlashCommandSuggestion] {
        guard let object = result.objectValue else {
            throw SlashCommandError.malformedResponse("commands.catalog result is not an object")
        }
        guard let pairs = object["pairs"]?.arrayValue else {
            throw SlashCommandError.malformedResponse("commands.catalog result missing 'pairs'")
        }
        guard let skills = object["skills"]?.objectValue else {
            throw SlashCommandError.malformedResponse("commands.catalog result missing 'skills'")
        }

        var descriptions: [String: String] = [:]
        var pairCounts: [String: Int] = [:]
        for pair in pairs {
            guard case .array(let fields) = pair,
                  let rawCommand = fields.first?.stringValue,
                  let command = Self.normalizedSlashToken(rawCommand) else {
                // A future non-command catalog row must not poison the whole
                // skill list. It cannot be selected safely, so skip it.
                continue
            }
            let key = command.lowercased()
            pairCounts[key, default: 0] += 1
            if descriptions[key] == nil {
                descriptions[key] = fields.dropFirst().first?.stringValue ?? ""
            }
        }

        let commandKeys = Set((object["commands"]?.objectValue ?? [:]).keys.compactMap {
            Self.normalizedSlashToken($0)?.lowercased()
        })

        return skills.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { rawKey in
                guard let command = Self.normalizedSlashToken(rawKey) else { return nil }
                let key = command.lowercased()
                // `commands` covers registry/plugin precedence. Duplicate
                // pairs cover quick-command collisions, which the gateway's
                // catalog exposes without a separate metadata map.
                guard commandKeys.contains(key) == false,
                      pairCounts[key] == 1,
                      let description = descriptions[key] else { return nil }
                return SlashCommandSuggestion(
                    text: command,
                    display: command,
                    description: description,
                    kind: .skill)
            }
    }

    /// Decode `complete.slash`, retaining only backend-labelled skill rows.
    /// Hermes uses that kind for bundles too; `completeSkills` performs the
    /// authoritative catalog intersection before exposing these suggestions.
    /// The UI never classifies a result by icon, name, or description.
    static func decodeSkillCompletions(_ result: JSONValue) throws -> [SlashCommandSuggestion] {
        guard let items = result["items"]?.arrayValue else {
            throw SlashCommandError.malformedResponse("complete.slash result missing 'items'")
        }
        return items.compactMap { item in
            guard let object = item.objectValue,
                  object["kind"]?.stringValue?.lowercased() == "skill",
                  let rawText = object["text"]?.stringValue,
                  let text = Self.normalizedSlashToken(rawText) else { return nil }
            let display = object["display"]?.stringValue?.isEmpty == false
                ? object["display"]!.stringValue!
                : text
            let description = object["meta"]?.stringValue ?? ""
            return SlashCommandSuggestion(
                text: text,
                display: display,
                description: description,
                kind: .skill)
        }
    }

    /// Decode `command.dispatch` and enforce the final type guard. The
    /// fallback display is only for older gateways that return the expanded
    /// message without the human-readable projection.
    static func decodeSkillDispatch(
        _ result: JSONValue,
        requestedName: String,
        argument: String
    ) throws -> SkillCommandDispatch {
        guard let object = result.objectValue else {
            throw SlashCommandError.malformedResponse("command.dispatch result is not an object")
        }
        guard let type = object["type"]?.stringValue else {
            throw SlashCommandError.malformedResponse("command.dispatch result missing 'type'")
        }
        guard type.lowercased() == "skill" else {
            throw SlashCommandError.notSkillCommand(requestedName)
        }
        guard let rawName = object["name"]?.stringValue,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlashCommandError.malformedResponse("skill dispatch result missing 'name'")
        }
        guard let message = object["message"]?.stringValue,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlashCommandError.malformedResponse("skill dispatch result missing non-empty 'message'")
        }
        // Hermes returns the skill's human frontmatter name here (for
        // example `Foo Bar`), not the slash route token Fleet requested.
        // Keep the validated requested slug as the command identity and use
        // the response name only as metadata validation.
        guard !requestedName.isEmpty,
              RoutingGuard.isValidRouteComponent(requestedName) else {
            throw SlashCommandError.invalidRequest("requested skill name is not a safe command token")
        }
        let fallbackDisplay = "/\(requestedName)" + (argument.isEmpty ? "" : argument.first?.isWhitespace == true ? argument : " \(argument)")
        let displayCandidate = object["display"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let display = if let displayCandidate, !displayCandidate.isEmpty {
            displayCandidate
        } else {
            fallbackDisplay
        }
        return SkillCommandDispatch(name: requestedName, message: message, display: display)
    }

    private static func normalizedSlashToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard token.hasPrefix("/"), token.count > 1 else { return nil }
        let name = String(token.dropFirst())
        guard RoutingGuard.isValidRouteComponent(name) else { return nil }
        return "/\(name)"
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
            throw SlashCommandError.rpcFailed(String(describing: error))
        }
    }

    static func mapRPCError(_ error: JSONRPCError, method: String) -> SlashCommandError {
        if error.code == -32601 {
            return .unsupportedCapability(method: method)
        }
        return .rpcFailed("\(error.message) (\(error.code))")
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
            return .rpcFailed(String(describing: error))
        }
    }
}
