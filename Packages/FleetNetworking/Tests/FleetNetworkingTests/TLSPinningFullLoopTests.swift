import XCTest
import Foundation
import FleetCore
@testable import FleetNetworking

/// T3 — full-loop TOFU pinning over a REAL TLS WebSocket connection: the
/// in-process TLS fixture presents a self-signed identity; the production
/// URLSessionWebSocketSessionFactory + PinningTrustHandler decide trust;
/// the transport classifies a rejected MITM as a pin mismatch.
final class TLSPinningFullLoopTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    private func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":false,"replay_epoch":"t3"}}}"#
    }

    private func makeTransport(
        baseURL: URL,
        pinStore: InMemoryPinStore
    ) -> GatewayWebSocketTransport {
        let handler = PinningTrustHandler(gatewayID: gatewayID, pinStore: pinStore)
        let factory = URLSessionWebSocketSessionFactory(trustHandler: handler)
        return GatewayWebSocketTransport(
            baseURL: baseURL,
            authentication: NoAuth(),
            sessionFactory: factory,
            configuration: TransportConfiguration(
                pingInterval: .seconds(3600),
                inboundDeadline: .seconds(3600),
                connectTimeout: .seconds(10),
                requestTimeout: .seconds(5)
            )
        )
    }

    private struct NoAuth: AuthenticationProviding {
        func authenticate() async throws -> ConnectionAuthentication { .none }
    }

    /// TOFU: first connect to the self-signed gateway trusts and PINS.
    func testFirstUseOverTLSTrustsAndPins() async throws {
        let pinStore = InMemoryPinStore()
        let server = try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(p12: TLSFixtureIdentities.gatewayP12))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            baseURL: URL(string: "https://127.0.0.1:\(server.listeningPort)")!,
            pinStore: pinStore)
        try await transport.connect()
        await transport.disconnect()

        let stored = try await pinStore.loadPin(for: gatewayID)
        XCTAssertEqual(stored?.base64String, TLSFixtureIdentities.gatewaySPKIBase64,
                       "TOFU first use must pin the gateway's SPKI")
        XCTAssertEqual(server.connectionCount, 1)
    }

    /// Reconnect with the SAME identity: pin matches, connects again.
    func testReconnectWithSameIdentityMatchesPin() async throws {
        let pinStore = InMemoryPinStore()
        try await pinStore.savePin(
            try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.gatewaySPKIBase64)),
            for: gatewayID)
        let server = try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(p12: TLSFixtureIdentities.gatewayP12))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            baseURL: URL(string: "https://127.0.0.1:\(server.listeningPort)")!,
            pinStore: pinStore)
        try await transport.connect()
        await transport.disconnect()
        XCTAssertEqual(server.connectionCount, 1)
    }

    /// MITM: the pinned gateway is expected, but a DIFFERENT key answers —
    /// the connection is rejected with the typed pin-mismatch reason and
    /// the gateway.ready handshake NEVER completes.
    func testMITMWithDifferentCertIsRejectedAsPinMismatch() async throws {
        let pinStore = InMemoryPinStore()
        try await pinStore.savePin(
            try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.gatewaySPKIBase64)),
            for: gatewayID)
        // The attacker presents the MITM identity.
        let server = try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(p12: TLSFixtureIdentities.mitmP12))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            baseURL: URL(string: "https://127.0.0.1:\(server.listeningPort)")!,
            pinStore: pinStore)

        do {
            try await transport.connect()
            XCTFail("MITM with a different key must be rejected")
        } catch let error as TransportError {
            guard case .connectionClosed(let reason) = error else {
                return XCTFail("expected connectionClosed, got \(error)")
            }
            XCTAssertEqual(reason, .tlsPinMismatch,
                           "a different presented key must classify as pin mismatch")
        }
        // The pin must be UNCHANGED by the rejected attempt.
        let stored = try await pinStore.loadPin(for: gatewayID)
        XCTAssertEqual(stored?.base64String, TLSFixtureIdentities.gatewaySPKIBase64)
    }

    /// Reconnect policy: a pin mismatch must NEVER auto-reconnect (the user
    /// must explicitly re-trust the new certificate).
    func testReconnectPolicyNeverRetriesPinMismatch() {
        XCTAssertEqual(ReconnectPolicy.decision(for: .tlsPinMismatch), .doNotReconnect)
    }
}
