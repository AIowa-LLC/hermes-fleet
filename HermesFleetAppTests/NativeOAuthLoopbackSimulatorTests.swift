import Foundation
import Network
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

        let code = "simulator-code"
        let state = "simulator-state"
        let response = try await sendLoopbackRequest(redirectURI: redirectURI, code: code, state: state)
        let responseString = try XCTUnwrap(String(data: response, encoding: .utf8))
        XCTAssertTrue(responseString.hasPrefix("HTTP/1.1 302 Found"))
        XCTAssertTrue(responseString.contains("Location: hermes-fleet://oauth-callback"))

        let callback = try await listener.waitForCallback(timeout: 5)
        XCTAssertEqual(callback.code, code)
        XCTAssertEqual(callback.state, state)
    }

    private func sendLoopbackRequest(redirectURI: String, code: String, state: String) async throws -> Data {
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
            "GET /cb?code=\(code)&state=\(state) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8
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
