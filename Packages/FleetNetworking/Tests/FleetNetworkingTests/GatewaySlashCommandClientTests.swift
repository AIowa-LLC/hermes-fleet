import XCTest
import FleetCore
@testable import FleetNetworking

/// Slash-command parity — wire decode contracts for `commands.catalog`,
/// `complete.slash`, `command.dispatch`, and `slash.exec`, mirroring
/// hermes-agent 0.21.3 shapes (`tui_gateway/contracts/tools_commands.py`,
/// `apps/shared/src/slash.ts::parseCommandDispatch`).
final class GatewaySlashCommandClientTests: XCTestCase {

    // MARK: commands.catalog

    func testCatalogDecodesFullCommandSurfaceWithMetaAndSkills() throws {
        let result: JSONValue = .object([
            "pairs": .array([
                .array([.string("/new"), .string("Start a new session")]),
                .array([.string("/steer"), .string("Inject a message after the next tool call")]),
                .array([.string("/redraw"), .string("Force a full UI repaint")]),
                .array([.string("/deploy-check"), .string("exec: fleet-status")]),
                .array([.string("/hermes-change-review"), .string("Review a change against its issue")]),
            ]),
            "canon": .object([
                "/reset": .string("/new"),
                "/fork": .string("/branch"),
            ]),
            "commands": .object([
                "/new": .object([
                    "argument_mode": .string("text"),
                    "desktop": .null,
                ]),
                "/reset": .object([
                    "argument_mode": .string("text"),
                    "desktop": .null,
                ]),
                "/redraw": .object([
                    "argument_mode": .null,
                    "desktop": .string("terminal"),
                ]),
            ]),
            "skills": .object([
                "/hermes-change-review": .object([
                    "usage": .number(4),
                    "origin": .string("local"),
                ]),
            ]),
            "skill_count": .number(1),
            "warning": .string(""),
        ])

        let catalog = try GatewaySlashCommandClient.decodeCatalog(result)

        // Backend order preserved.
        XCTAssertEqual(catalog.commands.map(\.text), [
            "/new", "/steer", "/redraw", "/deploy-check", "/hermes-change-review",
        ])
        // Registry meta: argument modes + desktop dispositions attached.
        let new = catalog.commands[0]
        XCTAssertEqual(new.kind, .command)
        XCTAssertEqual(new.argumentMode, .text)
        XCTAssertNil(new.desktopDisposition)
        // Terminal disposition preserved for the router.
        let redraw = catalog.commands[2]
        XCTAssertEqual(redraw.desktopDisposition, "terminal")
        // Quick/plugin command (no registry meta) is an extension row.
        XCTAssertEqual(catalog.commands[3].kind, .extensionCommand)
        // Skill row carries usage from the skills map.
        let skill = catalog.commands[4]
        XCTAssertEqual(skill.kind, .skill)
        XCTAssertEqual(skill.usage, 4)
        XCTAssertEqual(catalog.skills["/hermes-change-review"]?.origin, "local")
        // Canon aliases resolve.
        XCTAssertEqual(catalog.canonicalForm(of: "/reset"), "/new")
        // commandMeta: the registry map for EVERY command AND alias — typed
        // completion rows (`complete.slash`) carry no disposition, so
        // `ConversationViewModel.row(_:enrichedWith:)` reads them from here.
        // An empty map silently no-ops that enrichment on a real gateway.
        XCTAssertEqual(catalog.commandMeta["/new"]?.argumentMode, .text)
        XCTAssertEqual(catalog.commandMeta["/redraw"]?.desktopDisposition, "terminal")
        XCTAssertEqual(catalog.commandMeta["/reset"]?.argumentMode, .text,
                       "aliases ride the meta map too (no pairs row exists for them)")
        XCTAssertEqual(catalog.commandMeta["/reset"]?.canonical, "/new")
        XCTAssertNil(catalog.commandMeta["/deploy-check"], "quick/plugin commands are not registry meta")
        // No warning surfaces when the string is empty.
        XCTAssertNil(catalog.warning)
    }

    func testCatalogWarningSurfacesWhenNonEmpty() throws {
        let result: JSONValue = .object([
            "pairs": .array([]),
            "warning": .string("quick commands unavailable"),
        ])
        let catalog = try GatewaySlashCommandClient.decodeCatalog(result)
        XCTAssertEqual(catalog.warning, "quick commands unavailable")
    }

    func testCatalogRequiresPairsAndObject() {
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeCatalog(.array([]))) { error in
            XCTAssertEqual(error as? SlashCommandError, .malformedResponse("commands.catalog result is not an object"))
        }
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeCatalog(.object([:]))) { error in
            XCTAssertEqual(error as? SlashCommandError, .malformedResponse("commands.catalog result missing 'pairs'"))
        }
    }

    // MARK: complete.slash

    func testCompletionDecodesCommandAndSkillKindsWithBackendOrder() throws {
        let result: JSONValue = .object([
            "items": .array([
                .object([
                    "text": .string("/steer"),
                    "display": .string("/steer"),
                    "meta": .string("Inject a message after the next tool call"),
                    "kind": .string("command"),
                ]),
                .object([
                    "text": .string("/hermes-change-review"),
                    "display": .string("/hermes-change-review"),
                    "meta": .string("Review a change against its issue"),
                    "kind": .string("skill"),
                ]),
            ]),
        ])
        let decoded = try GatewaySlashCommandClient.decodeCompletions(result)
        XCTAssertEqual(decoded.map(\.text), ["/steer", "/hermes-change-review"])
        XCTAssertEqual(decoded[0].kind, .command)
        XCTAssertEqual(decoded[1].kind, .skill)
        XCTAssertEqual(decoded[0].description, "Inject a message after the next tool call")
    }

    func testCompletionUnknownKindFailsOpenAsUnknownNotDropped() throws {
        // A future backend kind must not be silently dropped — it stays
        // addressable as .unknown for honest handling upstream.
        let result: JSONValue = .object([
            "items": .array([
                .object([
                    "text": .string("/weird"),
                    "kind": .string("hologram"),
                ]),
            ]),
        ])
        let decoded = try GatewaySlashCommandClient.decodeCompletions(result)
        XCTAssertEqual(decoded.map(\.text), ["/weird"])
        XCTAssertEqual(decoded[0].kind, .unknown)
    }

    // MARK: command.dispatch — every directive

    func testDispatchDecodesEveryKnownDirective() throws {
        XCTAssertEqual(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("exec"), "output": .string("done"),
            ])),
            .exec(output: "done", warning: nil))
        XCTAssertEqual(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("plugin"), "output": .string("plugin out"),
            ])),
            .plugin(output: "plugin out"))
        XCTAssertEqual(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("alias"), "target": .string("new"),
            ])),
            .alias(target: "new"))
        XCTAssertEqual(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("send"),
                "message": .string("model text"),
                "display": .string("/goal fix the leak"),
                "notice": .string("⊙ Goal set"),
            ])),
            .send(message: "model text", display: "/goal fix the leak", notice: "⊙ Goal set"))
        XCTAssertEqual(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("skill"),
                "name": .string("Foo Bar"),
                "message": .string("expanded body"),
                "display": .string("/work fix the leak"),
            ])),
            .skill(message: "expanded body", display: "/work fix the leak"))
        XCTAssertEqual(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("prefill"),
                "message": .string("draft"),
                "notice": .string("Backed up 1 turn"),
            ])),
            .prefill(message: "draft", notice: "Backed up 1 turn"))
    }

    func testDispatchUnknownTypeFailsClosed() {
        XCTAssertThrowsError(
            try GatewaySlashCommandClient.decodeDispatch(.object([
                "type": .string("holodeck"),
            ]))
        ) { error in
            XCTAssertEqual(error as? SlashCommandError, .unknownDispatchType("holodeck"))
        }
    }

    func testDispatchMalformedDirectivesThrow() {
        // Missing type.
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeDispatch(.object([:])))
        // alias without target.
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeDispatch(.object([
            "type": .string("alias"),
        ])))
        // send without message.
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeDispatch(.object([
            "type": .string("send"),
        ])))
        // skill without message.
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeDispatch(.object([
            "type": .string("skill"), "name": .string("x"),
        ])))
        // prefill without message.
        XCTAssertThrowsError(try GatewaySlashCommandClient.decodeDispatch(.object([
            "type": .string("prefill"),
        ])))
    }

    // MARK: slash.exec

    func testExecutionPlainOutputAndWarning() throws {
        let execution = try GatewaySlashCommandClient.decodeExecution(.object([
            "output": .string("worker text"),
            "warning": .string("careful"),
        ]))
        XCTAssertEqual(execution.output, "worker text")
        XCTAssertEqual(execution.warning, "careful")
        XCTAssertNil(execution.dispatch)
    }

    func testExecutionStructuredDispatchRouting() throws {
        let execution = try GatewaySlashCommandClient.decodeExecution(.object([
            "type": .string("skill"),
            "name": .string("x"),
            "message": .string("expanded"),
        ]))
        XCTAssertEqual(execution.dispatch, .skill(message: "expanded", display: nil))
        XCTAssertNil(execution.output)
    }

    // MARK: Error mapping

    func testMethodNotFoundMapsToUnsupportedCapability() {
        let error = JSONRPCError(code: -32601, message: "Method not found", data: nil)
        let mapped = GatewaySlashCommandClient.mapRPCError(error, method: "commands.catalog")
        XCTAssertEqual(mapped, .unsupportedCapability(method: "commands.catalog"))
    }

    func testStopProcessesDecodesKilledCount() throws {
        // Wire shape verified: process.stop → {killed: N}.
        let result: JSONValue = .object(["killed": .number(2)])
        XCTAssertEqual(GatewaySlashCommandClient.intValue(result["killed"]), 2)
    }

    // MARK: integer decoding — the 2^63 trap boundary

    func testIntValueRejectsTheTwoToTheSixtyThreeBoundaryInsteadOfTrapping() {
        // `Double(Int.max)` rounds UP to exactly 2^63, so it is NOT a valid
        // upper bound: a finite payload value AT that boundary passed the old
        // guard and `Int(n)` trapped (fatal error, process death). intValue is
        // fed from network JSON (`skills` usage, `process.stop` killed), so a
        // buggy/hostile gateway could crash the app.
        let boundary = Double(Int.max)
        XCTAssertEqual(boundary, 9_223_372_036_854_775_808.0, "Double(Int.max) IS 2^63")
        XCTAssertNil(GatewaySlashCommandClient.intValue(.number(boundary)),
                     "a value at 2^63 must decode to nil, never reach Int(_:)")
        XCTAssertNil(GatewaySlashCommandClient.intValue(.number(boundary * 2)),
                     "and neither must anything above it")
        // The largest Double below 2^63 still converts exactly.
        let largestSafe = boundary - 1_024
        XCTAssertEqual(GatewaySlashCommandClient.intValue(.number(largestSafe)), Int(largestSafe))
    }

    func testIntValueKeepsItsExistingRejections() {
        XCTAssertEqual(GatewaySlashCommandClient.intValue(.number(0)), 0)
        XCTAssertEqual(GatewaySlashCommandClient.intValue(.number(2.9)), 2, "truncates, as before")
        XCTAssertNil(GatewaySlashCommandClient.intValue(.number(-1)))
        XCTAssertNil(GatewaySlashCommandClient.intValue(.number(.nan)))
        XCTAssertNil(GatewaySlashCommandClient.intValue(.number(.infinity)))
        XCTAssertNil(GatewaySlashCommandClient.intValue(nil))
        XCTAssertNil(GatewaySlashCommandClient.intValue(.string("2")))
    }

    func testCatalogSkillUsageAtTheIntegerBoundaryDecodesWithoutTrapping() throws {
        // End-to-end through the decoder that consumes the value.
        let result: JSONValue = .object([
            "pairs": .array([.array([.string("/hermes-change-review"), .string("Review a change")])]),
            "skills": .object([
                "/hermes-change-review": .object([
                    "usage": .number(9_223_372_036_854_775_808.0),
                    "origin": .string("local"),
                ]),
            ]),
        ])
        let catalog = try GatewaySlashCommandClient.decodeCatalog(result)
        XCTAssertEqual(catalog.skills["/hermes-change-review"]?.usage, 0,
                       "an out-of-range usage count degrades to 0, never a trap")
        XCTAssertEqual(catalog.commands.first?.usage, 0)
    }

    // MARK: slash.exec — the stripped command must still name a command

    func testExecuteRejectsSlashOnlyCommandsBeforeAnyRpc() async throws {
        // The slash-prefix guard validates `trimmed`, but slash.exec is sent
        // the STRIPPED form (`drop(while: "/")`), so `//` / `///` passed the
        // guard and shipped an EMPTY command to the gateway.
        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)))
        let client = GatewaySlashCommandClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        for command in ["//", "///", " //", "/// "] {
            do {
                _ = try await client.execute(sessionID: "abc12345", command: command)
                XCTFail("\(command) must not reach slash.exec")
            } catch let error as SlashCommandError {
                guard case .invalidRequest = error else {
                    return XCTFail("expected .invalidRequest for \(command), got \(error)")
                }
            }
        }
    }
}
