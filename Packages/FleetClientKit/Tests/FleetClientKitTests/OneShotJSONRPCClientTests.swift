import XCTest
import FleetCore
@testable import FleetClientKit

/// Scripted `URLProtocol`: answers requests without a network. The TLS pin path
/// is covered by `SPKIPinningTests` (a stubbed protocol never presents a
/// certificate); these tests cover request shape, limits, and error redaction.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int = 200
        var body: Data = Data()
        var declaredLength: Int64?
        var delay: TimeInterval = 0
        var error: URLError?
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    private static let lock = NSLock()

    static func reset(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        self.stub = stub
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stub = Self.stub
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        Self.lock.unlock()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay) { [self] in
            let headers = stub.declaredLength.map { ["Content-Length": String($0)] }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class OneShotJSONRPCClientTests: XCTestCase {
    private let endpoint = URL(string: "https://gateway.example.test/rpc")!

    private func makeClient(timeout: TimeInterval = 5) -> OneShotJSONRPCClient {
        OneShotJSONRPCClient(
            gatewayID: GatewayID(rawValue: "synthetic-gateway"),
            pinStore: FixedPinStore(pins: [:]),
            timeout: timeout,
            sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            })
    }

    private func reply(_ json: String, status: Int = 200) -> StubURLProtocol.Stub {
        StubURLProtocol.Stub(status: status, body: Data(json.utf8))
    }

    func testReturnsTheResultAndSendsAJSONRPCEnvelope() async throws {
        StubURLProtocol.reset(reply(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#))
        let result = try await makeClient().call(
            endpoint: endpoint, method: "approval.respond",
            params: .object(["choice": .string("deny")]), bearerToken: "synthetic-token")
        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 5)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(StubURLProtocol.lastBody)) as? [String: Any]
        XCTAssertEqual(body?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(body?["method"] as? String, "approval.respond")
        XCTAssertEqual((body?["params"] as? [String: Any])?["choice"] as? String, "deny")
    }

    func testRejectsNonHTTPSAndCredentialBearingEndpointsWithoutSending() async {
        StubURLProtocol.reset(reply(#"{"jsonrpc":"2.0","id":1,"result":1}"#))
        let bad = [
            "http://gateway.example.test/rpc",
            "https://user:pass@gateway.example.test/rpc",
            "https://gateway.example.test/rpc?token=abc",
            "https://gateway.example.test/rpc#frag",
            "wss://gateway.example.test/rpc",
        ]
        for text in bad {
            do {
                _ = try await makeClient().call(endpoint: URL(string: text)!, method: "m")
                XCTFail("expected invalidEndpoint for \(text)")
            } catch {
                XCTAssertEqual(error as? OneShotRPCError, .invalidEndpoint)
            }
        }
        XCTAssertNil(StubURLProtocol.lastRequest, "no request was sent for a rejected endpoint")
    }

    func testRPCErrorIsRedactedAndBounded() async {
        let secret = "Bearer abcdefghijklmnop"
        let message = String(repeating: "x", count: 2_000) + " \(secret)"
        StubURLProtocol.reset(reply(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"\#(message)"}}"#))
        do {
            _ = try await makeClient().call(endpoint: endpoint, method: "m")
            XCTFail("expected an rpc error")
        } catch OneShotRPCError.rpcError(let code, let text) {
            XCTAssertEqual(code, -32000)
            XCTAssertLessThanOrEqual(text.count, 600)
            XCTAssertFalse(text.contains("abcdefghijklmnop"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNon2xxSurfacesOnlyTheStatusCode() async {
        StubURLProtocol.reset(reply("secret server text", status: 503))
        do {
            _ = try await makeClient().call(endpoint: endpoint, method: "m")
            XCTFail("expected httpStatus")
        } catch {
            XCTAssertEqual(error as? OneShotRPCError, .httpStatus(503))
            XCTAssertFalse("\(error)".contains("secret server text"))
        }
    }

    func testMalformedAndResultlessRepliesAreRejected() async {
        for body in ["not json", #"{"jsonrpc":"2.0","id":1}"#, #"{"jsonrpc":"1.0","id":1,"result":1}"#] {
            StubURLProtocol.reset(reply(body))
            do {
                _ = try await makeClient().call(endpoint: endpoint, method: "m")
                XCTFail("expected malformedResponse for \(body)")
            } catch {
                XCTAssertEqual(error as? OneShotRPCError, .malformedResponse)
            }
        }
    }

    func testOversizedResponsesAreRejected() async {
        var stub = reply(#"{"jsonrpc":"2.0","id":1,"result":"\#(String(repeating: "a", count: 300_000))"}"#)
        StubURLProtocol.reset(stub)
        do {
            _ = try await makeClient().call(endpoint: endpoint, method: "m")
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? OneShotRPCError, .responseTooLarge)
        }
        // A server that declares an oversized body up front is refused early.
        stub = reply("{}")
        stub.declaredLength = Int64(OneShotJSONRPCClient.maximumResponseBytes) + 1
        StubURLProtocol.reset(stub)
        do {
            _ = try await makeClient().call(endpoint: endpoint, method: "m")
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? OneShotRPCError, .responseTooLarge)
        }
    }

    func testTimeoutIsBoundedAndTyped() async {
        var stub = reply(#"{"jsonrpc":"2.0","id":1,"result":1}"#)
        stub.error = URLError(.timedOut)
        StubURLProtocol.reset(stub)
        do {
            _ = try await makeClient().call(endpoint: endpoint, method: "m")
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? OneShotRPCError, .timeout)
        }
    }

    func testNetworkFailuresCarryOnlyANumericCode() async {
        var stub = reply("")
        stub.error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://gateway.example.test/rpc?token=abc"])
        StubURLProtocol.reset(stub)
        do {
            _ = try await makeClient().call(endpoint: endpoint, method: "m")
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(error as? OneShotRPCError, .network(code: URLError.cannotConnectToHost.rawValue))
            XCTAssertFalse("\(error)".contains("token=abc"))
        }
    }

    func testTimeoutIsClamped() async throws {
        StubURLProtocol.reset(reply(#"{"jsonrpc":"2.0","id":1,"result":1}"#))
        _ = try await makeClient(timeout: 9_999).call(endpoint: endpoint, method: "m")
        XCTAssertEqual(StubURLProtocol.lastRequest?.timeoutInterval, 30)
        _ = try await makeClient(timeout: 0).call(endpoint: endpoint, method: "m")
        XCTAssertEqual(StubURLProtocol.lastRequest?.timeoutInterval, 1)
    }
}
