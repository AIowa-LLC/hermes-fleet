import XCTest
import FleetCore
@testable import FleetNetworking

/// Phase B ingest mapping: wire payloads → `ServerRequest` / `ApprovalRequest`
/// → `InboxItem`. Fixtures are synthetic. The point under test is identity
/// stability (one request, one item, however it was delivered) and that no
/// secret value survives into the inbox model.
final class GatewayInboxIngestTests: XCTestCase {
    private let gateway = GatewayID(rawValue: "gw-synthetic")
    private let session = "synthetic-session-1"
    private let now = Date(timeIntervalSince1970: 1_000)

    private func agent() -> InboxAgentIdentity {
        InboxAgentIdentity(gatewayID: gateway, gatewayLabel: "Synthetic Gateway", sessionID: session)
    }

    private func decodeOK(_ method: String, _ params: [String: JSONValue], id: String = "srq-0001") throws -> ServerRequest {
        let result = GatewayServerRequestDecoder.decode(
            id: .string(id), method: method, params: .object(params), replayed: false)
        guard case .success(let request) = result else {
            XCTFail("expected \(method) to decode")
            throw XCTSkip("decode failed")
        }
        return request
    }

    func testServerApprovalAndReplayedApprovalYieldTheSameItem() throws {
        let params: [String: JSONValue] = [
            "session_id": .string(session),
            "request_id": .string("req-synthetic-1"),
            "command": .string("echo synthetic"),
            "description": .string("synthetic danger"),
            "choices": .array([.string("once"), .string("deny")]),
        ]
        let live = try decodeOK("approval", params, id: "srq-0001")
        let replayed = ServerRequest(id: live.id, sessionID: live.sessionID, kind: live.kind, replayed: true)

        let first = InboxItem.make(from: live, agent: agent(), at: now)
        let second = InboxItem.make(from: replayed, agent: agent(), at: now.addingTimeInterval(30))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, InboxItemID(gatewayID: gateway, sessionID: session, requestID: "req-synthetic-1"))
        XCTAssertEqual(first.serverRequestID, "srq-0001")
        XCTAssertEqual(first.context.choices, ["once", "deny"])
    }

    func testLegacyApprovalEventCollapsesOntoServerRequestItem() throws {
        let request = try decodeOK("approval", [
            "session_id": .string(session),
            "request_id": .string("req-synthetic-2"),
            "command": .string("echo synthetic"),
        ], id: "srq-0002")
        let server = InboxItem.make(from: request, agent: agent(), at: now)

        let legacyPayload: JSONValue = .object([
            "request_id": .string("req-synthetic-2"),
            "command": .string("echo synthetic"),
        ])
        let legacyRequest = try XCTUnwrap(GatewayApprovalClient.decodeApprovalRequest(
            payload: legacyPayload, sessionID: session))
        let legacy = InboxItem.approval(from: legacyRequest, agent: agent(), at: now)

        // Same item, though one answers via JSON-RPC and the other via approval.respond.
        XCTAssertEqual(server.id, legacy.id)
        XCTAssertEqual(server.serverRequestID, "srq-0002")
        XCTAssertNil(legacy.serverRequestID)
    }

    func testSecretPromptIsIngestedWithoutAnyValueField() throws {
        let request = try decodeOK("secret", [
            "session_id": .string(session),
            "env_var": .string("SYNTHETIC_API_KEY"),
            "prompt": .string("Enter the synthetic key"),
            "value": .string("SYNTHETIC-SECRET-VALUE"),
        ], id: "srq-0003")
        let item = InboxItem.make(from: request, agent: agent(), at: now)

        XCTAssertEqual(item.kind, .secret)
        XCTAssertEqual(item.context.envVarName, "SYNTHETIC_API_KEY")
        let encoded = try String(decoding: JSONEncoder().encode(item), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SYNTHETIC-SECRET-VALUE"))
    }

    func testUnsupportedMethodIsNotIngested() {
        let result = GatewayServerRequestDecoder.decode(
            id: .string("srq-9"), method: "vault.read", params: .object(["session_id": .string(session)]), replayed: false)
        guard case .failure = result else { return XCTFail("unsupported methods must not reach the inbox") }
    }
}
