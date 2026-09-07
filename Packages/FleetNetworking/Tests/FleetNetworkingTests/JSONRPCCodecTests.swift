import XCTest
import FleetNetworking

final class JSONRPCCodecTests: XCTestCase {
    // MARK: encode/decode round trips

    func testEncodeRequestRoundTrip() throws {
        let request = JSONRPCRequest(id: .string("w1"), method: "session.create", params: .object(["profile": .string("fleet")]))
        let line = try JSONRPCCodec.encode(.request(request))
        XCTAssertFalse(line.contains("\n"), "encoded frame must be a single line")

        let decoded = try JSONRPCCodec.decode(line)
        guard case .request(let r) = decoded else { return XCTFail("expected request") }
        XCTAssertEqual(r.id, .string("w1"))
        XCTAssertEqual(r.method, "session.create")
        XCTAssertEqual(r.params?["profile"]?.stringValue, "fleet")
        XCTAssertEqual(r.jsonrpc, "2.0")
    }

    func testEncodeNumericIDRequest() throws {
        let request = JSONRPCRequest(id: .number(7), method: "gateway.ping", params: .object([:]))
        let line = try JSONRPCCodec.encode(.request(request))
        let decoded = try JSONRPCCodec.decode(line)
        guard case .request(let r) = decoded else { return XCTFail("expected request") }
        XCTAssertEqual(r.id, .number(7))
    }

    func testDecodeResponse() throws {
        let line = #"{"jsonrpc":"2.0","id":"w1","result":{"ok":true}}"#
        let decoded = try JSONRPCCodec.decode(line)
        guard case .response(let r) = decoded else { return XCTFail("expected response") }
        XCTAssertEqual(r.id, .string("w1"))
        XCTAssertEqual(r.result?["ok"]?.boolValue, true)
    }

    func testDecodeErrorResponse() throws {
        let line = #"{"jsonrpc":"2.0","id":"w1","error":{"code":-32602,"message":"bad params"}}"#
        let decoded = try JSONRPCCodec.decode(line)
        guard case .error(let e) = decoded else { return XCTFail("expected error") }
        XCTAssertEqual(e.id, .string("w1"))
        XCTAssertEqual(e.error.code, -32602)
        XCTAssertEqual(e.error.message, "bad params")
    }

    func testDecodeEvent() throws {
        let line = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":true,"replay_epoch":"abc","change_events":true}}}"#
        let decoded = try JSONRPCCodec.decode(line)
        guard case .event(let e) = decoded else { return XCTFail("expected event") }
        XCTAssertEqual(e.method, "event")
        let gatewayEvent = GatewayEvent(event: e)
        XCTAssertNotNil(gatewayEvent)
        XCTAssertEqual(gatewayEvent?.type, .gatewayReady)
        XCTAssertEqual(gatewayEvent?.ready?.heartbeat, true)
        XCTAssertEqual(gatewayEvent?.ready?.replayEpoch, "abc")
    }

    func testDecodeParseError() {
        XCTAssertThrowsError(try JSONRPCCodec.decode("not json")) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32700)
        }
    }

    func testDecodeInvalidRequest() {
        let line = #"{"foo":"bar"}"#
        XCTAssertThrowsError(try JSONRPCCodec.decode(line)) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32600)
        }
    }

    func testDecodeWrongVersion() {
        let line = #"{"jsonrpc":"1.0","id":"x","method":"m"}"#
        XCTAssertThrowsError(try JSONRPCCodec.decode(line)) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32600)
        }
    }

    func testDecodeUnknownFieldsTolerated() throws {
        // Tolerant decoding: unknown/extra fields must not break parsing.
        let line = #"{"jsonrpc":"2.0","id":"w9","method":"session.list","params":{},"extra":"ignored"}"#
        let decoded = try JSONRPCCodec.decode(line)
        guard case .request(let r) = decoded else { return XCTFail("expected request") }
        XCTAssertEqual(r.method, "session.list")
    }

    // MARK: stream framing

    func testDecodeStreamFramesOnNewlines() throws {
        let a = try JSONRPCCodec.encode(.request(JSONRPCRequest(id: .string("a"), method: "m1", params: nil)))
        let b = try JSONRPCCodec.encode(.request(JSONRPCRequest(id: .string("b"), method: "m2", params: nil)))
        let data = Data((a + "\n" + b + "\n").utf8)
        let result = JSONRPCCodec.decodeStream(data)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.partial.isEmpty)
    }

    func testDecodeStreamKeepsPartialLine() throws {
        let a = try JSONRPCCodec.encode(.request(JSONRPCRequest(id: .string("a"), method: "m1", params: nil)))
        var data = Data((a + "\n").utf8)
        data.append(Data(#"{"jsonrpc":"2.0","id":"b","method"#.utf8)) // truncated
        let result = JSONRPCCodec.decodeStream(data)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertFalse(result.partial.isEmpty)
    }

    // MARK: JSONValue

    func testJSONValueCoding() throws {
        let value: JSONValue = .object([
            "n": .number(1.5),
            "s": .string("x"),
            "b": .bool(true),
            "arr": .array([.string("y"), .null]),
            "nested": .object(["k": .string("v")]),
        ])
        let data = try JSONRPCCodec.encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["nested"]?["k"]?.stringValue, "v")
        XCTAssertEqual(decoded["arr"]?.arrayValue?.count, 2)
    }
}
