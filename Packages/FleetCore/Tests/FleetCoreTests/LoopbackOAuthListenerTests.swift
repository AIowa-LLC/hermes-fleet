import XCTest
import Network
@testable import FleetCore

/// Loopback OAuth listener — startup, callback capture, missing-code fail-closed.
/// Synthetic loopback only; no live gateway.
final class LoopbackOAuthListenerTests: XCTestCase {

    func testListenerParametersRequireIPv4Loopback() {
        let parameters = LoopbackOAuthListener.listenerParameters()
        XCTAssertEqual(
            parameters.requiredLocalEndpoint,
            .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any))
    }

    func testListenerStartsAndExposesLoopbackRedirectURI() async throws {
        do {
            let listener = try await LoopbackOAuthListener()
            defer { Task { await listener.stop() } }
            let redirectURI = await listener.redirectURI
            XCTAssertTrue(redirectURI.hasPrefix("http://127.0.0.1:"))
            XCTAssertTrue(redirectURI.hasSuffix("/cb"))
            let portString = redirectURI.dropFirst("http://127.0.0.1:".count).prefix { $0 != "/" }
            XCTAssertNotNil(UInt16(portString))
            XCTAssertNotEqual(UInt16(portString), 0)
        } catch NativeOAuthError.internalError(let detail) where detail.contains("Invalid argument") {
            throw XCTSkip("NWListener ephemeral bind is unavailable in this host test environment: \(detail)")
        }
    }

    func testListenerCapturesCallbackAndRedirectsToAppScheme() async throws {
        let listener: LoopbackOAuthListener
        do {
            listener = try await LoopbackOAuthListener()
        } catch NativeOAuthError.internalError(let detail) where detail.contains("Invalid argument") {
            throw XCTSkip("NWListener ephemeral bind is unavailable in this host test environment: \(detail)")
        }
        let redirectURI = await listener.redirectURI
        let testCode = "test_auth_code_12345"
        let testState = "test_state_abcde"
        let callbackTask = Task {
            try await listener.waitForCallback(timeout: 5)
        }
        let response = try await sendLoopbackRequest(
            to: redirectURI,
            requestTarget: "/cb?code=\(testCode)&state=\(testState)"
        )
        let responseString = try XCTUnwrap(String(data: response, encoding: .utf8))
        XCTAssertTrue(responseString.hasPrefix("HTTP/1.1 302 Found"))
        XCTAssertTrue(responseString.contains("Location: hermes-fleet://oauth-callback"))
        XCTAssertTrue(responseString.contains("code=\(testCode)"))
        XCTAssertTrue(responseString.contains("state=\(testState)"))

        let result = try await callbackTask.value
        XCTAssertEqual(result.code, testCode)
        XCTAssertEqual(result.state, testState)
    }

    func testListenerRejectsCallbackWithMissingCode() async throws {
        let listener: LoopbackOAuthListener
        do {
            listener = try await LoopbackOAuthListener()
        } catch NativeOAuthError.internalError(let detail) where detail.contains("Invalid argument") {
            throw XCTSkip("NWListener ephemeral bind is unavailable in this host test environment: \(detail)")
        }
        let redirectURI = await listener.redirectURI

        let callbackTask = Task {
            try await listener.waitForCallback(timeout: 5)
        }
        _ = try await sendLoopbackRequest(to: redirectURI, requestTarget: "/cb?state=test_state")

        do {
            _ = try await callbackTask.value
            XCTFail("expected missingCode")
        } catch NativeOAuthError.missingCode {
            // expected
        }
    }

    func testParseCallbackPercentDecodesValues() {
        let request = "GET /cb?code=abc%2Fdef&state=s%20t HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let parsed = LoopbackOAuthListener.parseCallback(request)
        XCTAssertEqual(parsed.code, "abc/def")
        XCTAssertEqual(parsed.state, "s t")
    }

    func testParseCallbackMissingQueryReturnsNil() {
        let parsed = LoopbackOAuthListener.parseCallback("GET /cb HTTP/1.1\r\n\r\n")
        XCTAssertNil(parsed.code)
        XCTAssertNil(parsed.state)
    }

    func testParseCallbackRejectsOtherPaths() {
        let parsed = LoopbackOAuthListener.parseCallback(
            "GET /other?code=abc&state=expected HTTP/1.1\r\n\r\n")
        XCTAssertNil(parsed.code)
        XCTAssertNil(parsed.state)
    }

    private func sendLoopbackRequest(to redirectURI: String, requestTarget: String) async throws -> Data {
        let components = try XCTUnwrap(URLComponents(string: redirectURI))
        let portValue = try XCTUnwrap(components.port)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(portValue)))
        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port),
            using: .tcp
        )
        defer { connection.cancel() }
        connection.start(queue: .global(qos: .userInitiated))

        let request = Data(
            "GET \(requestTarget) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: request, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
        }
    }
}
