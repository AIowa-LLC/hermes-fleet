import XCTest
import FleetCore
@testable import FleetNetworking

final class GatewaySlashCommandClientTests: XCTestCase {

    func testCatalogUsesAuthoritativeSkillsAndOmitsCollisions() throws {
        let result: JSONValue = .object([
            "pairs": .array([
                .array([.string("/review"), .string("Review changes")]),
                .array([.string("/shadowed"), .string("Built-in command")]),
                // A quick command collision is exposed as a duplicate pair.
                .array([.string("/quick"), .string("Quick command")]),
                .array([.string("/quick"), .string("Skill with same token")]),
            ]),
            "skills": .object([
                "/review": .object([:]),
                "/shadowed": .object([:]),
                "/quick": .object([:]),
                "/not-in-pairs": .object([:]),
            ]),
            "commands": .object([
                "/shadowed": .object(["argument_mode": .string("text")]),
            ]),
        ])

        let decoded = try GatewaySlashCommandClient.decodeSkillCatalog(result)

        XCTAssertEqual(decoded, [
            SlashCommandSuggestion(
                text: "/review",
                description: "Review changes",
                kind: .skill),
        ])
    }

    func testCompletionKeepsOnlyBackendIdentifiedSkills() throws {
        let result: JSONValue = .object([
            "items": .array([
                .object([
                    "text": .string("/review"),
                    "display": .string("/review"),
                    "meta": .string("Review changes"),
                    "kind": .string("skill"),
                ]),
                .object([
                    "text": .string("/reload"),
                    "display": .string("/reload"),
                    "meta": .string("Reload"),
                    "kind": .string("command"),
                ]),
            ]),
        ])

        let decoded = try GatewaySlashCommandClient.decodeSkillCompletions(result)

        XCTAssertEqual(decoded.map(\.text), ["/review"])
        XCTAssertEqual(decoded.first?.description, "Review changes")
    }

    func testDispatchRequiresSkillTypeAndNonEmptyMessage() throws {
        let valid: JSONValue = .object([
            "type": .string("skill"),
            // Hermes returns the human frontmatter name, not the slash slug.
            "name": .string("Foo Bar"),
            "message": .string("expanded instructions"),
            "display": .string("/hermes-change-review Review this PR"),
        ])
        let decoded = try GatewaySlashCommandClient.decodeSkillDispatch(
            valid,
            requestedName: "hermes-change-review",
            argument: "Review this PR")
        XCTAssertEqual(decoded.name, "hermes-change-review")
        XCTAssertEqual(decoded.message, "expanded instructions")
        XCTAssertEqual(decoded.display, "/hermes-change-review Review this PR")

        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeSkillDispatch(
            .object(["type": .string("exec"), "output": .string("wrong path")]),
            requestedName: "review",
            argument: "")) { error in
            XCTAssertEqual(error as? SlashCommandError, .notSkillCommand("review"))
        }

        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeSkillDispatch(
            .object(["type": .string("skill"), "name": .string("review"), "message": .string(" ")]),
            requestedName: "review",
            argument: "")) { error in
            XCTAssertEqual(
                error as? SlashCommandError,
                .malformedResponse("skill dispatch result missing non-empty 'message'"))
        }

        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeSkillDispatch(
            .object(["type": .string("skill"), "name": .string("Foo Bar"), "message": .string("expanded")]),
            requestedName: "review/",
            argument: "")) { error in
            XCTAssertEqual(
                error as? SlashCommandError,
                .invalidRequest("requested skill name is not a safe command token"))
        }
    }

    func testMethodNotFoundMapsToUnsupportedCapability() {
        XCTAssertEqual(
            GatewaySlashCommandClient.mapRPCError(
                JSONRPCError(code: -32601, message: "method not found"),
                method: "complete.slash"),
            .unsupportedCapability(method: "complete.slash"))
    }

    func testSlashRPCsUseExactMethodsAndParameters() async throws {
        let recorder = SlashRequestRecorder()
        let script = InProcessWebSocketServer.Script(
            onOpen: [#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#],
            onText: { frame in
                guard let request = Self.request(frame) else { return [] }
                recorder.record(method: request.method, params: request.params)
                switch request.method {
                case "commands.catalog":
                    return [Self.response(id: request.id, result: [
                        "pairs": [
                            ["/review", "Review changes"],
                            ["/shadowed", "Shadowed skill"],
                        ],
                        "skills": [
                            "/review": [:],
                            "/shadowed": [:],
                        ],
                        "commands": ["/shadowed": ["argument_mode": "text"]],
                    ])]
                case "complete.slash":
                    return [Self.response(id: request.id, result: [
                        "items": [[
                            "text": "/review",
                            "display": "/review",
                            "meta": "Review changes",
                            "kind": "skill",
                        ], [
                            // Hermes also labels bundles as kind: skill; the
                            // catalog intersection must remove this row.
                            "text": "/bundle",
                            "display": "/bundle",
                            "meta": "A skill bundle",
                            "kind": "skill",
                        ], [
                            // The catalog exposes this token as shadowed by a
                            // higher-precedence command, so it must be removed.
                            "text": "/shadowed",
                            "display": "/shadowed",
                            "meta": "Shadowed skill",
                            "kind": "skill",
                        ]],
                    ])]
                case "command.dispatch":
                    return [Self.response(id: request.id, result: [
                        "type": "skill",
                        "name": "Foo Bar",
                        "message": "expanded",
                        "display": "/review Check the diff",
                    ])]
                default:
                    return []
                }
            })
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30), inboundDeadline: .seconds(30),
                connectTimeout: .seconds(10), requestTimeout: .seconds(2)))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewaySlashCommandClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let completions = try await client.completeSkills(sessionID: "s1", text: "/rev")
        XCTAssertEqual(completions.map(\.text), ["/review"])
        let dispatch = try await client.dispatchSkill(
            sessionID: "s1", name: "review", argument: "Check the diff")
        XCTAssertEqual(dispatch.name, "review")
        XCTAssertEqual(dispatch.message, "expanded")
        XCTAssertEqual(dispatch.display, "/review Check the diff")

        XCTAssertEqual(recorder.methods, ["commands.catalog", "complete.slash", "command.dispatch"])
        XCTAssertEqual(recorder.params[0]["session_id"] as? String, "s1")
        XCTAssertEqual(recorder.params[1]["session_id"] as? String, "s1")
        XCTAssertEqual(recorder.params[1]["text"] as? String, "/rev")
        XCTAssertEqual(recorder.params[2]["session_id"] as? String, "s1")
        XCTAssertEqual(recorder.params[2]["name"] as? String, "review")
        XCTAssertEqual(recorder.params[2]["arg"] as? String, "Check the diff")
    }

    private struct Request {
        let id: String
        let method: String
        let params: [String: Any]
    }

    private static func request(_ frame: String) -> Request? {
        guard let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else { return nil }
        return Request(id: id, method: method, params: object["params"] as? [String: Any] ?? [:])
    }

    private static func response(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": result,
        ])
        return String(data: data, encoding: .utf8)!
    }
}

private final class SlashRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _methods: [String] = []
    private var _params: [[String: Any]] = []

    var methods: [String] {
        lock.lock(); defer { lock.unlock() }
        return _methods
    }

    var params: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _params
    }

    func record(method: String, params: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        _methods.append(method)
        _params.append(params)
    }
}
