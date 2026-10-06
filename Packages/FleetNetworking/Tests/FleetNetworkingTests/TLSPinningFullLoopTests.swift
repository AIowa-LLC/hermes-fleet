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
        let handler = PinningTrustHandler(gatewayID: gatewayID, pinStore: pinStore, approvalStore: pinStore)
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
        try pinStore.syncApproveFirstUse(boundTo: try gatewayKey, for: gatewayID)
        let server = try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(
                certificateDER: TLSFixtureIdentities.gatewayCertificateDER,
                privateKeyX963: TLSFixtureIdentities.gatewayPrivateKeyX963))
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
        XCTAssertNil(server.failureDescription)
    }

    /// Reconnect with the SAME identity: pin matches, connects again.
    func testReconnectWithSameIdentityMatchesPin() async throws {
        let pinStore = InMemoryPinStore()
        try await pinStore.savePin(
            try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.gatewaySPKIBase64)),
            for: gatewayID)
        let server = try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(
                certificateDER: TLSFixtureIdentities.gatewayCertificateDER,
                privateKeyX963: TLSFixtureIdentities.gatewayPrivateKeyX963))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            baseURL: URL(string: "https://127.0.0.1:\(server.listeningPort)")!,
            pinStore: pinStore)
        try await transport.connect()
        await transport.disconnect()
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertNil(server.failureDescription)
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
            identity: try TLSFixtureIdentities.identity(
                certificateDER: TLSFixtureIdentities.mitmCertificateDER,
                privateKeyX963: TLSFixtureIdentities.mitmPrivateKeyX963))
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

    // MARK: first-use review regressions (real TLS)

    private var gatewayKey: SPKIFingerprint {
        get throws { try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.gatewaySPKIBase64)) }
    }

    private func gatewayServer() throws -> InProcessTLSServer {
        try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(
                certificateDER: TLSFixtureIdentities.gatewayCertificateDER,
                privateKeyX963: TLSFixtureIdentities.gatewayPrivateKeyX963))
    }

    private func mitmServer() throws -> InProcessTLSServer {
        try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(
                certificateDER: TLSFixtureIdentities.mitmCertificateDER,
                privateKeyX963: TLSFixtureIdentities.mitmPrivateKeyX963))
    }

    /// The probe reports the key the server ACTUALLY presents and never lets
    /// a request reach the peer (the handshake is abandoned at the challenge).
    func testProbeReportsPresentedKeyWithoutCompletingAConnection() async throws {
        let server = try gatewayServer()
        try await server.start()
        defer { server.stop() }

        let key = try await TLSPresentedKeyProbe().presentedKey(
            for: URL(string: "https://127.0.0.1:\(server.listeningPort)")!)

        XCTAssertEqual(key, try gatewayKey)
        XCTAssertEqual(server.tlsCompletedCount, 0, "the handshake is abandoned before any request")
    }

    /// FIRST USE WITHOUT A REVIEWED KEY never connects and never pins — the
    /// unapproved "trust whatever appears first" shortcut no longer exists.
    func testUnapprovedFirstUseNeverConnectsOrPins() async throws {
        let pinStore = InMemoryPinStore()
        let server = try gatewayServer()
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(
            baseURL: URL(string: "https://127.0.0.1:\(server.listeningPort)")!, pinStore: pinStore)

        do { try await transport.connect(); XCTFail("unapproved first use must be rejected") } catch {}

        XCTAssertNil(try pinStore.syncLoadPin(for: gatewayID))
        XCTAssertEqual(server.tlsCompletedCount, 0, "no handshake completes, so no credential can reach the peer")
    }

    /// KEY CHANGED BETWEEN DISPLAY AND CONFIRMATION: the user approved the
    /// gateway key, but a different key answers the real connection. It must
    /// be rejected, must not pin, and must not consume the reviewed approval.
    func testKeyChangedAfterReviewIsRejectedAndNotPinned() async throws {
        let pinStore = InMemoryPinStore()
        try pinStore.syncApproveFirstUse(boundTo: try gatewayKey, for: gatewayID)
        let server = try mitmServer()
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(
            baseURL: URL(string: "https://127.0.0.1:\(server.listeningPort)")!, pinStore: pinStore)

        do { try await transport.connect(); XCTFail("a key other than the reviewed one must be rejected") } catch {}

        XCTAssertNil(try pinStore.syncLoadPin(for: gatewayID))
        XCTAssertTrue(try pinStore.syncIsFirstUseApproved(for: gatewayID))
        XCTAssertEqual(server.tlsCompletedCount, 0)
    }

    /// The approval is single-use: after the reviewed key pins, a later first
    /// use (pin cleared, no new review) is blocked again.
    func testApprovalIsSingleUseAcrossReconnectAfterPinCleared() async throws {
        let pinStore = InMemoryPinStore()
        try pinStore.syncApproveFirstUse(boundTo: try gatewayKey, for: gatewayID)
        let server = try InProcessTLSServer(
            scripts: [.init(onOpen: [readyFrame()]), .init(onOpen: [readyFrame()])],
            identity: try TLSFixtureIdentities.identity(
                certificateDER: TLSFixtureIdentities.gatewayCertificateDER,
                privateKeyX963: TLSFixtureIdentities.gatewayPrivateKeyX963))
        try await server.start()
        defer { server.stop() }
        let base = URL(string: "https://127.0.0.1:\(server.listeningPort)")!

        let first = makeTransport(baseURL: base, pinStore: pinStore)
        try await first.connect()
        await first.disconnect()
        XCTAssertEqual(try pinStore.syncLoadPin(for: gatewayID), try gatewayKey)

        try pinStore.syncDeletePin(for: gatewayID)
        let second = makeTransport(baseURL: base, pinStore: pinStore)
        do { try await second.connect(); XCTFail("re-pairing needs a fresh review") } catch {}
        XCTAssertNil(try pinStore.syncLoadPin(for: gatewayID))
    }

    /// RACE: two connections to the same gateway race for first use with one
    /// reviewed key. Both end up on the SAME pin; neither overwrites it.
    func testConcurrentFirstUseWithSameReviewedKeyConvergesOnOnePin() async throws {
        let pinStore = InMemoryPinStore()
        try pinStore.syncApproveFirstUse(boundTo: try gatewayKey, for: gatewayID)
        // Two listeners presenting the same reviewed key (the fixture serves
        // one live connection per listener).
        let s1 = try gatewayServer(), s2 = try gatewayServer()
        try await s1.start(); try await s2.start()
        defer { s1.stop(); s2.stop() }
        let a = makeTransport(baseURL: URL(string: "https://127.0.0.1:\(s1.listeningPort)")!, pinStore: pinStore)
        let b = makeTransport(baseURL: URL(string: "https://127.0.0.1:\(s2.listeningPort)")!, pinStore: pinStore)

        async let ra: Void = a.connect()
        async let rb: Void = b.connect()
        var failures = 0
        do { try await ra } catch { failures += 1 }
        do { try await rb } catch { failures += 1 }
        await a.disconnect(); await b.disconnect()

        XCTAssertEqual(failures, 0, "a racing connection for the same reviewed key is a pin match, not a failure")
        XCTAssertEqual(try pinStore.syncLoadPin(for: gatewayID), try gatewayKey)
    }

    /// RACE with an attacker: one reviewed key, two peers answer at once (the
    /// real gateway and a different key). Only the reviewed key can pin.
    func testConcurrentFirstUseOnlyReviewedKeyCanPin() async throws {
        let pinStore = InMemoryPinStore()
        try pinStore.syncApproveFirstUse(boundTo: try gatewayKey, for: gatewayID)
        let good = try gatewayServer(), bad = try mitmServer()
        try await good.start(); try await bad.start()
        defer { good.stop(); bad.stop() }
        let g = makeTransport(baseURL: URL(string: "https://127.0.0.1:\(good.listeningPort)")!, pinStore: pinStore)
        let m = makeTransport(baseURL: URL(string: "https://127.0.0.1:\(bad.listeningPort)")!, pinStore: pinStore)

        async let rm: Void = m.connect()
        async let rg: Void = g.connect()
        var mitmRejected = false
        do { try await rm } catch { mitmRejected = true }
        try await rg
        await g.disconnect()

        XCTAssertTrue(mitmRejected)
        XCTAssertEqual(try pinStore.syncLoadPin(for: gatewayID), try gatewayKey)
        XCTAssertEqual(bad.tlsCompletedCount, 0)
    }

    /// Reconnect policy: a pin mismatch must NEVER auto-reconnect (the user
    /// must explicitly re-trust the new certificate).
    func testReconnectPolicyNeverRetriesPinMismatch() {
        XCTAssertEqual(ReconnectPolicy.decision(for: .tlsPinMismatch), .doNotReconnect)
    }
}
