import Foundation
import XCTest
@testable import FleetCore

/// Exercise the one-time OAuth callback on an iOS Simulator. macOS host
/// runners cannot bind this Network.framework loopback listener, so the
/// equivalent FleetCore package cases skip there.
final class NativeOAuthLoopbackSimulatorTests: XCTestCase {
    func testLoopbackListenerCapturesOnlyItsCallbackOnSimulator() async throws {
        let listener = try await LoopbackOAuthListener()
        defer { Task { await listener.stop() } }

        let redirectURI = await listener.redirectURI
        XCTAssertTrue(redirectURI.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(redirectURI.hasSuffix("/cb"))

        let callbackTask = Task {
            try await listener.waitForCallback(timeout: 5)
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        let code = "simulator-code"
        let state = "simulator-state"
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(redirectURI)?code=\(code)&state=\(state)")))
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertTrue(try XCTUnwrap(http.value(forHTTPHeaderField: "Location"))
            .hasPrefix("hermes-fleet://oauth-callback"))

        let callback = try await callbackTask.value
        XCTAssertEqual(callback.code, code)
        XCTAssertEqual(callback.state, state)
    }
}
