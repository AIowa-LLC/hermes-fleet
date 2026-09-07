import XCTest
import FleetCore
import FleetNetworking

/// F1 (t_e41b16e0) — honest connection-failure classification.
///
/// The production defect: the auth REST clients (providers / password-login /
/// ws-ticket) let their raw errors escape; the transport's generic catch
/// classified them as `DisconnectReason.unknown` → `.offline` → the UI said
/// "Unreachable" for EVERY cause — a rejected password (401) and a wrong
/// port (404) were indistinguishable from a dead host.
///
/// These tests pin the full classification chain:
///   AuthenticationError.httpStatus(N)
///     → TransportError.authSurfaceStatus(N)      (transport connect catch)
///     → GatewayConnectivityError.authSurfaceHTTP(N) (SingleGatewayConnection.map)
///     → GatewayStatus: 401/403 = .authenticationRequired, else .unsupported
final class F1FailureClassificationTests: XCTestCase {

    // MARK: GatewayStatus mapping (the §13 classification)

    func testAuthSurface401ClassifiesAuthenticationRequired() {
        XCTAssertEqual(
            GatewayStatus(connectivityError: .authSurfaceHTTP(401)),
            .authenticationRequired,
            "401 from the auth surface means the credential was rejected — never 'unreachable'")
    }

    func testAuthSurface403ClassifiesAuthenticationRequired() {
        XCTAssertEqual(
            GatewayStatus(connectivityError: .authSurfaceHTTP(403)),
            .authenticationRequired)
    }

    func testAuthSurface404ClassifiesUnsupportedNotOffline() {
        // The exact Tony case: 100.127.200.89:8642 answers TCP but 404s every
        // app route. The endpoint ANSWERED — "Unreachable" is a lie.
        XCTAssertEqual(
            GatewayStatus(connectivityError: .authSurfaceHTTP(404)),
            .unsupported)
    }

    func testAuthSurface500ClassifiesUnsupported() {
        XCTAssertEqual(
            GatewayStatus(connectivityError: .authSurfaceHTTP(500)),
            .unsupported)
    }

    // MARK: SingleGatewayConnection error mapping

    func testTransportAuthSurfaceStatusMapsToAuthSurfaceHTTP() async throws {
        // The private `map` is exercised end-to-end through connect() below;
        // here we verify via the full chain on a real connection object.
        for status in [404, 401] {
            struct HTTPStatusAuthenticator: AuthenticationProviding {
                let status: Int
                func authenticate() async throws -> ConnectionAuthentication {
                    throw AuthenticationError.httpStatus(status)
                }
            }
            let transport = GatewayWebSocketTransport(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                authentication: HTTPStatusAuthenticator(status: status),
                configuration: TransportConfiguration(
                    pingInterval: .seconds(30),
                    inboundDeadline: .seconds(30),
                    connectTimeout: .seconds(2),
                    requestTimeout: .seconds(2))
            )
            let connection = SingleGatewayConnection(
                gatewayID: GatewayID(rawValue: "arch"),
                displayName: "Arch",
                endpoint: URL(string: "http://127.0.0.1:1")!,
                transport: transport
            )
            do {
                try await connection.connect()
                XCTFail("expected authSurfaceHTTP(\(status))")
            } catch let error as GatewayConnectivityError {
                XCTAssertEqual(error, .authSurfaceHTTP(status))
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testAuthSurfaceErrorDescriptionsAreNonSecret() {
        let cases: [GatewayConnectivityError] = [
            .authSurfaceHTTP(401),
            .authSurfaceHTTP(404),
        ]
        for error in cases {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("password"), "no secret material in \(text)")
            XCTAssertTrue(text.contains("HTTP"), "status code surfaces: \(text)")
        }
    }

    // MARK: transport connect() catch — the seam that was generic

    /// A scripted authenticator throwing the typed HTTP-status error must be
    /// classified by the transport's connect(), not swallowed as unknown.
    func testTransportConnectClassifiesAuthSurfaceHTTPStatus() async throws {
        struct HTTPStatusAuthenticator: AuthenticationProviding {
            let status: Int
            func authenticate() async throws -> ConnectionAuthentication {
                throw AuthenticationError.httpStatus(status)
            }
        }

        for status in [401, 404] {
            let transport = GatewayWebSocketTransport(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                authentication: HTTPStatusAuthenticator(status: status),
                configuration: TransportConfiguration(
                    pingInterval: .seconds(30),
                    inboundDeadline: .seconds(30),
                    connectTimeout: .seconds(2),
                    requestTimeout: .seconds(2))
            )
            do {
                try await transport.connect()
                XCTFail("expected authSurfaceStatus(\(status))")
            } catch let error as TransportError {
                XCTAssertEqual(error, .authSurfaceStatus(status),
                               "HTTP \(status) must surface as authSurfaceStatus, not unknown/offline")
            } catch {
                XCTFail("unexpected error \(error)")
            }
            // The observable state carries the DisconnectReason by design
            // (D1); the HTTP classification travels on the thrown error,
            // which is what testConnection / roster / AppEnvironment
            // classify through GatewayStatus(connectivityError:).
            if status == 401, case .failed(let detail) = transport.state {
                XCTAssertTrue(detail.contains("reauthentication"),
                              "401 observable detail must be auth-flavored: \(detail)")
            }
        }
    }

    /// The end-to-end chain through SingleGatewayConnection.connect().
    func testConnectionClassifiesAuthSurface404AsUnsupported() async throws {
        struct NotFoundAuthenticator: AuthenticationProviding {
            func authenticate() async throws -> ConnectionAuthentication {
                throw AuthenticationError.httpStatus(404)
            }
        }
        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            authentication: NotFoundAuthenticator(),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30),
                inboundDeadline: .seconds(30),
                connectTimeout: .seconds(2),
                requestTimeout: .seconds(2))
        )
        let connection = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "arch"),
            displayName: "Arch",
            endpoint: URL(string: "http://127.0.0.1:1")!,
            transport: transport
        )
        do {
            try await connection.connect()
            XCTFail("expected authSurfaceHTTP(404)")
        } catch let error as GatewayConnectivityError {
            XCTAssertEqual(error, .authSurfaceHTTP(404))
            XCTAssertEqual(GatewayStatus(connectivityError: error), .unsupported)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testConnectionClassifiesAuthSurface401AsAuthenticationRequired() async throws {
        struct RejectedAuthenticator: AuthenticationProviding {
            func authenticate() async throws -> ConnectionAuthentication {
                throw AuthenticationError.httpStatus(401)
            }
        }
        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            authentication: RejectedAuthenticator(),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30),
                inboundDeadline: .seconds(30),
                connectTimeout: .seconds(2),
                requestTimeout: .seconds(2))
        )
        let connection = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "arch"),
            displayName: "Arch",
            endpoint: URL(string: "http://127.0.0.1:1")!,
            transport: transport
        )
        do {
            try await connection.connect()
            XCTFail("expected authSurfaceHTTP(401)")
        } catch let error as GatewayConnectivityError {
            XCTAssertEqual(error, .authSurfaceHTTP(401))
            XCTAssertEqual(GatewayStatus(connectivityError: error), .authenticationRequired)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
