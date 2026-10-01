import XCTest
@testable import FleetCore

/// Loopback OAuth listener — startup, callback capture, missing-code fail-closed.
/// Synthetic loopback only; no live gateway.
final class LoopbackOAuthListenerTests: XCTestCase {

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
        let callbackURL = "\(redirectURI)?code=\(testCode)&state=\(testState)"

        let callbackTask = Task {
            try await listener.waitForCallback(timeout: 5)
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: callbackURL)!)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        let location = try XCTUnwrap(http.value(forHTTPHeaderField: "Location"))
        XCTAssertTrue(location.hasPrefix("hermes-fleet://oauth-callback"))
        XCTAssertTrue(location.contains("code=\(testCode)"))
        XCTAssertTrue(location.contains("state=\(testState)"))

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
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "\(redirectURI)?state=test_state")!)
        request.httpMethod = "GET"
        _ = try await URLSession.shared.data(for: request)

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
}
