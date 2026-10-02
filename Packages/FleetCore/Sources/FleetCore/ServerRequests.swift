import Foundation

/// P0.1 — server→client JSON-RPC request domain.
///
/// Hermes gateways newer than upstream commit 9f7f2f28c0 no longer push
/// `approval.request` / `*.respond` pairs to a client that advertised
/// `client.capabilities {server_requests: true}`. Instead the gateway sends a
/// JSON-RPC REQUEST (string id `srq-<hex>`) and the client answers with a
/// normal JSON-RPC RESPONSE carrying the same id. Verified against
/// `tui_gateway/server_requests.py` and the generated OpenRPC contract
/// (`apps/shared/src/gateway-contract.openrpc.json`, `x-server-requests`):
///
/// | method     | params (besides `session_id`)                   | result            |
/// | ---------- | ----------------------------------------------- | ----------------- |
/// | `approval` | `request_id, command, description, choices, …`  | `{choice, all?}`  |
/// | `clarify`  | `question, choices?, multi_select?` or `questions` | `{answer}` / `{answers}` / `{}` |
/// | `sudo`     | `command`                                       | `{value}`         |
/// | `secret`   | `env_var, prompt, metadata?`                    | `{value}`         |
///
/// This file owns only the typed vocabulary. Decoding lives in
/// `FleetNetworking`; answering goes through `ServerPromptResponding` /
/// `ApprovalsProviding` so FleetUI never imports the transport.
public enum ServerRequestMethod {
    public static let approval = "approval"
    public static let clarify = "clarify"
    public static let sudo = "sudo"
    public static let secret = "secret"

    /// The methods Fleet can render and answer. Every other server→client
    /// method (`preview.*`, `terminal.read`, `vault.*`, `tour`, …) is answered
    /// with JSON-RPC `-32601` so the agent fails fast instead of waiting out
    /// its deadline.
    public static let supported: Set<String> = [approval, clarify, sudo, secret]
}

/// One question of a clarify request (`ClarifyQuestion` in the contract).
public struct ClarifyQuestion: Identifiable, Hashable, Sendable {
    /// Question id used by `clarify.lock`. Empty for a single-question request.
    public let qid: String
    public let question: String
    /// Offered choices; empty means free text only.
    public let choices: [String]
    public let multiSelect: Bool

    public init(qid: String, question: String, choices: [String] = [], multiSelect: Bool = false) {
        self.qid = qid
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect && !choices.isEmpty
    }

    public var id: String { qid }
}

/// A `clarify` request: one question, or a batch answered one lock at a time.
public struct ClarifyPrompt: Hashable, Sendable {
    public let sessionID: String
    public let questions: [ClarifyQuestion]
    /// True when the wire carried `questions` (answers lock via `clarify.lock`).
    public let isBatch: Bool
    /// Answers the server already accepted; only present on a reconnect replay.
    public let lockedAnswers: [String: String]

    public init(
        sessionID: String,
        questions: [ClarifyQuestion],
        isBatch: Bool,
        lockedAnswers: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.questions = questions
        self.isBatch = isBatch
        self.lockedAnswers = lockedAnswers
    }
}

/// A `sudo` request. Carries only the (server-redacted) command; the password
/// the user types is never part of this model.
public struct SudoPrompt: Hashable, Sendable {
    public let sessionID: String
    public let command: String

    public init(sessionID: String, command: String) {
        self.sessionID = sessionID
        self.command = command
    }
}

/// A `secret` request for a named environment variable. Carries the variable
/// NAME and the prompt copy; the value the user types is never part of this
/// model.
public struct SecretPrompt: Hashable, Sendable {
    public let sessionID: String
    public let envVar: String
    public let prompt: String

    public init(sessionID: String, envVar: String, prompt: String) {
        self.sessionID = sessionID
        self.envVar = envVar
        self.prompt = prompt
    }
}

public enum ServerRequestKind: Hashable, Sendable {
    case approval(ApprovalRequest)
    case clarify(ClarifyPrompt)
    case sudo(SudoPrompt)
    case secret(SecretPrompt)

    /// The wire method name.
    public var method: String {
        switch self {
        case .approval: return ServerRequestMethod.approval
        case .clarify: return ServerRequestMethod.clarify
        case .sudo: return ServerRequestMethod.sudo
        case .secret: return ServerRequestMethod.secret
        }
    }
}

/// One open server→client request as a conversation surface sees it.
public struct ServerRequest: Identifiable, Hashable, Sendable {
    /// The JSON-RPC id (`srq-<hex>`). Stable across a reconnect: the gateway
    /// re-delivers an unanswered request under the same id via
    /// `open_requests`, and `request.cancel` names it.
    public let id: String
    public let sessionID: String
    public let kind: ServerRequestKind
    /// True when it arrived through `open_requests` (resume / `events.since`)
    /// rather than live.
    public let replayed: Bool

    public init(id: String, sessionID: String, kind: ServerRequestKind, replayed: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.replayed = replayed
    }

    public var method: String { kind.method }
}

/// Outcome of a `clarify.lock` call.
public enum ClarifyLockStatus: Hashable, Sendable {
    /// Locked; `remaining` lists the question ids still unanswered. The lock
    /// that empties it resolves the request server-side.
    case locked(remaining: [String])
    /// The wait already ended (timeout / cancel / answered elsewhere). Not an
    /// error: the prompt is simply dismissed.
    case expired
}

/// Answers a non-approval server→client request. Lives in FleetCore so
/// FleetUI never imports FleetNetworking; the concrete client is wired by the
/// composition root. Fail-closed: an implementation that cannot reach the
/// gateway throws — a failed answer must never look like success.
public protocol ServerPromptResponding: Sendable {
    /// Answer a single-question clarify. An empty string means skipped.
    func answerClarify(requestID: String, answer: String) async throws

    /// Lock one answer of a batch clarify (`clarify.lock`; editable until
    /// every question is locked).
    func lockClarifyAnswer(requestID: String, questionID: String, answer: String) async throws -> ClarifyLockStatus

    /// Cancel a whole clarify request (an empty result frame; the agent sees
    /// "no answer").
    func cancelClarify(requestID: String) async throws

    /// Answer a `sudo` / `secret` request with its one string value. An empty
    /// string means skipped / declined. The value is sent and forgotten:
    /// implementations must not cache, persist, or log it.
    func answerValue(requestID: String, value: String) async throws
}

/// Sessions whose concrete type carries the server-prompt seam.
/// `GatewayConversationSession` conforms in FleetNetworking; the UI resolves it
/// with ONE cast at build time (same discipline as `ApprovalsCapable`).
public protocol ServerPromptCapable: ConversationSessionProviding {
    var serverPrompts: any ServerPromptResponding { get }
}

/// Fail-closed default for sessions without server-request support.
public struct UnsupportedServerPrompts: ServerPromptResponding {
    public init() {}

    public func answerClarify(requestID: String, answer: String) async throws {
        throw ConversationError.notConnected
    }

    public func lockClarifyAnswer(requestID: String, questionID: String, answer: String) async throws -> ClarifyLockStatus {
        throw ConversationError.notConnected
    }

    public func cancelClarify(requestID: String) async throws {
        throw ConversationError.notConnected
    }

    public func answerValue(requestID: String, value: String) async throws {
        throw ConversationError.notConnected
    }
}

/// Wire encoding of a multi-select clarify answer: a JSON array of the chosen
/// labels, matching what the Hermes desktop client sends
/// (`JSON.stringify(chosen)`) and what the gateway's
/// `_parse_multi_select_response` accepts.
public enum ClarifyAnswerEncoding {
    public static func multiSelect(_ chosen: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: chosen),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
