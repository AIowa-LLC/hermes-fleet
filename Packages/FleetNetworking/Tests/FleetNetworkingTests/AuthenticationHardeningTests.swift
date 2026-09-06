import XCTest
import os
import FleetCore
import FleetNetworking

/// M11 Authentication Hardening (FleetNetworking side):
/// - `WSTicket` redaction + client-side TTL enforcement (single-use, 30s).
/// - `WSTicketClient` redacted description (session token never prints).
/// - `GatewayAuthenticator` (ticket / loopback-token / none paths).
/// - Transport URL building for `?ticket=` and `?token=`.
/// - 4401 re-auth surfaces `.authenticationRequired` and reconnect re-mints a
///   FRESH ticket — never a silent retry with the same credential (spec §8.6).
final class AuthenticationHardeningTests: XCTestCase {

    /// Minimal in-memory `CredentialStoring` stub (FleetCore seam) so the
    /// loopback + session-token auth paths are exercised hermetically without
    /// FleetSecurity. Mirrors the store the U2 UI writes via saveCredential.
    private final class StubCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            lock.withLock { $0[gatewayID.rawValue] = credential.rawValue }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { storage in
                storage[gatewayID.rawValue].map { GatewayCredential(rawValue: $0) }
            }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            _ = lock.withLock { storage in storage.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    /// Minimal connection stub (L1 fix #1 test): connect succeeds, no socket.
    private struct StubConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        let connectResult: Result<GatewayReadyAdoption?, GatewayConnectivityError>
        var status: GatewayStatus {
            switch connectResult {
            case .success: return .online
            case .failure(let error): return GatewayStatus(connectivityError: error)
            }
        }
        func adoptedReady() async -> GatewayReadyAdoption? {
            if case .success(let ready) = connectResult { return ready }
            return nil
        }
        func connect() async throws {
            if case .failure(let error) = connectResult { throw error }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    // MARK: WSTicket — redaction (spec §16/§29)

    func testWSTicketDescriptionIsRedacted() {
        let ticket = WSTicket(token: "super-secret-ticket-value", ttlSeconds: 30)
        XCTAssertEqual(ticket.description, "[REDACTED]")
        XCTAssertEqual(ticket.debugDescription, "WSTicket(redacted)")
        XCTAssertFalse(ticket.description.contains("super-secret"))
        XCTAssertFalse("\(ticket)".contains("super-secret"))
    }

    // MARK: WSTicket — client-side TTL enforcement (synthesis §11: 30s TTL)

    func testWSTicketNotExpiredWithinTTL() {
        let ticket = WSTicket(token: "t", ttlSeconds: 30, mintedAt: Date().addingTimeInterval(-10))
        XCTAssertFalse(ticket.isExpired(asOf: Date()))
    }

    func testWSTicketExpiredAfterTTL() {
        let ticket = WSTicket(token: "t", ttlSeconds: 30, mintedAt: Date().addingTimeInterval(-31))
        XCTAssertTrue(ticket.isExpired(asOf: Date()))
    }

    // MARK: WSTicketClient — redacted description (spec §29)

    func testWSTicketClientDescriptionNeverIncludesSessionToken() {
        let client = WSTicketClient(
            baseURL: URL(string: "http://192.168.50.58:9119")!,
            sessionToken: "loopback-secret-token")
        XCTAssertFalse(client.description.contains("loopback-secret"))
        XCTAssertFalse("\(client)".contains("loopback-secret"))
        XCTAssertTrue(client.description.contains("192.168.50.58"))
    }

    // MARK: GatewayAuthenticator — ticket path

    func testAuthenticatorTicketPathMintsAndWraps() async throws {
        struct Minter: WSTicketMinting {
            func mintTicket() async throws -> WSTicket {
                WSTicket(token: "fresh-ticket", ttlSeconds: 30)
            }
        }
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "workstation"),
            strategy: .sessionToken,
            ticketMinter: Minter())
        let result = try await auth.authenticate()
        guard case .ticket(let token) = result else {
            return XCTFail("expected ticket auth, got \(result)")
        }
        XCTAssertEqual(token.rawValue, "fresh-ticket")
        XCTAssertEqual(result.description, "[REDACTED]")
    }

    func testAuthenticatorRejectsExpiredTicket() async throws {
        struct ExpiredMinter: WSTicketMinting {
            func mintTicket() async throws -> WSTicket {
                WSTicket(token: "stale-ticket", ttlSeconds: 30,
                         mintedAt: Date().addingTimeInterval(-60))
            }
        }
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "workstation"),
            strategy: .sessionToken,
            ticketMinter: ExpiredMinter())
        do {
            _ = try await auth.authenticate()
            XCTFail("expected ticketExpired")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .ticketExpired)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: GatewayAuthenticator — loopback token path (credential-store-backed)

    func testAuthenticatorLoopbackTokenPath() async throws {
        let store = StubCredentialStore()
        try await store.saveCredential(GatewayCredential(rawValue: "loop-token"), for: GatewayID(rawValue: "workstation"))
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "workstation"),
            strategy: .loopbackToken,
            credentialStore: store)
        let result = try await auth.authenticate()
        guard case .loopbackToken(let token) = result else {
            return XCTFail("expected loopbackToken auth, got \(result)")
        }
        XCTAssertEqual(token.rawValue, "loop-token")
    }

    func testAuthenticatorLoopbackMissingThrows() async {
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "workstation"),
            strategy: .loopbackToken,
            credentialStore: StubCredentialStore())
        do {
            _ = try await auth.authenticate()
            XCTFail("expected missingLoopbackToken")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .missingLoopbackToken)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: L1 fix #1 — the loopback authenticator reads the SAME credential
    // store the U2 UI writes via saveCredential (was: a different
    // KeychainTokenStore that nothing ever wrote → missingLoopbackToken).

    func testLoopbackCredentialStoredViaRegistryReachesAuthenticator() async throws {
        // Reproduce the L1 store-split: save a credential the way the U2 UI
        // does (GatewayRegistryService.saveCredential → CredentialStoring),
        // then authenticate a loopback gateway against that SAME store.
        let store = StubCredentialStore()
        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: store,
            connectionFactory: { gateway, _ in
                StubConnection(gatewayID: gateway.id, connectResult: .success(nil))
            }
        )
        let gateway = try await registry.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:9119")!,
            authConfiguration: GatewayAuthConfiguration(strategy: .loopbackToken, credentialStored: false)
        ))
        try await registry.saveCredential(GatewayCredential(rawValue: "ui-entered-token"), for: gateway.id)

        let auth = GatewayAuthenticator(
            gatewayID: gateway.id,
            strategy: .loopbackToken,
            credentialStore: store)
        let result = try await auth.authenticate()
        guard case .loopbackToken(let token) = result else {
            return XCTFail("expected loopbackToken auth, got \(result)")
        }
        XCTAssertEqual(token.rawValue, "ui-entered-token",
                       "the UI-entered credential (KeychainCredentialStore path) must authenticate a loopback gateway")
    }

    // MARK: L1 fix #3 — a .sessionToken gateway's stored credential is sent
    // as X-Hermes-Session-Token on POST /api/auth/ws-ticket (was: built with
    // sessionToken: nil → dead ticket minter).

    func testSessionTokenAuthenticatorSendsStoredCredentialAsHeader() async throws {
        // A real WSTicketClient backed by a URLProtocol mock captures the
        // request, so we can prove the stored credential is sent as the
        // X-Hermes-Session-Token header on the mint call.
        TicketMintURLProtocol.statusCode = 200
        TicketMintURLProtocol.body = Data(#"{"ticket":"abc123","ttl_seconds":30}"#.utf8)
        TicketMintURLProtocol.capturedRequests = []
        defer { TicketMintURLProtocol.capturedRequests = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TicketMintURLProtocol.self]
        let session = URLSession(configuration: config)

        let store = StubCredentialStore()
        try await store.saveCredential(GatewayCredential(rawValue: "dashboard-session-token"), for: GatewayID(rawValue: "workstation"))
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "workstation"),
            strategy: .sessionToken,
            credentialStore: store,
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            urlSession: session)
        let result = try await auth.authenticate()
        guard case .ticket(let token) = result else {
            return XCTFail("expected ticket auth, got \(result)")
        }
        XCTAssertEqual(token.rawValue, "abc123")
        let request = try XCTUnwrap(TicketMintURLProtocol.capturedRequests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
            "dashboard-session-token",
            "the stored credential must be sent as X-Hermes-Session-Token on the mint")
    }

    // MARK: GatewayAuthenticator — none path

    func testAuthenticatorNonePath() async throws {
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "workstation"),
            strategy: .none)
        let result = try await auth.authenticate()
        XCTAssertEqual(result, .none)
    }

    // MARK: Transport URL building — ticket vs loopback token (synthesis §11)

    func testBuildWebSocketURLLoopbackToken() {
        let base = URL(string: "http://127.0.0.1:9119")!
        let url = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws",
            authentication: .loopbackToken(StoredToken(rawValue: "loop-secret")))
        XCTAssertEqual(url?.scheme, "ws")
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })
        XCTAssertEqual(query?.value, "loop-secret")
    }

    func testBuildWebSocketURLTicketParam() {
        let base = URL(string: "http://127.0.0.1:9119")!
        let url = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws",
            authentication: .ticket(StoredToken(rawValue: "ticket-secret")))
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ticket" })
        XCTAssertEqual(query?.value, "ticket-secret")
    }

    func testBuildWebSocketURLNoneHasNoAuthQuery() {
        let base = URL(string: "http://127.0.0.1:9119")!
        let url = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws", authentication: .none)
        let names = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? []
        XCTAssertFalse(names.contains("ticket"))
        XCTAssertFalse(names.contains("token"))
    }

    func testBuiltAuthURLIsRedactable() {
        let base = URL(string: "http://127.0.0.1:9119")!
        let url = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws",
            authentication: .ticket(StoredToken(rawValue: "top-secret-ticket")))!
        let redacted = Redaction.redactedURL(url)
        XCTAssertFalse(redacted.contains("top-secret-ticket"))
        XCTAssertTrue(redacted.contains("ticket="))
    }

    // MARK: 4401 → re-auth, no silent retry (spec §8.6 / synthesis §11)

    /// After a 4401 close the connection surfaces `.authenticationRequired`
    /// and a reconnect mints a NEW ticket (re-auth), never reusing the same
    /// credential and never retrying silently.
    func testReauthenticateMintsFreshTicket() async throws {
        final class CountingMinter: WSTicketMinting, @unchecked Sendable {
            private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
            var count: Int { lock.withLock { $0 } }
            func mintTicket() async throws -> WSTicket {
                let n = lock.withLock { value in
                    value += 1
                    return value
                }
                return WSTicket(token: "ticket-\(n)", ttlSeconds: 30)
            }
        }
        let minter = CountingMinter()
        // Script 1: healthy (ready). Script 2: also healthy — the reconnect
        // after re-auth must reach a fresh connection.
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(replayEpoch: "epoch-1")],
            onText: { frame in
                if frame.contains("\"gateway.ping\"") {
                    guard let id = Self.extractID(from: frame) else { return [] }
                    return [Self.pongFrame(id: id)]
                }
                return []
            })
        let server = try InProcessWebSocketServer(scripts: [script, script])
        try await server.start()
        defer { server.stop() }

        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            ticketMinter: minter,
            configuration: TransportConfiguration(
                pingInterval: .seconds(30), inboundDeadline: .seconds(30),
                connectTimeout: .seconds(2), requestTimeout: .seconds(5))
        )
        let connection = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            transport: transport)

        try await connection.connect()
        XCTAssertEqual(connection.status, .online)
        XCTAssertEqual(minter.count, 1, "first connect mints one ticket")

        // Force a 4401 (bad credential) after connect.
        server.sendClose(code: 4401)
        let deadline = Date().addingTimeInterval(3)
        while connection.status != .authenticationRequired && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(connection.status, .authenticationRequired,
                       "4401 must surface authenticationRequired, never silent retry")

        // Explicit re-authentication: reconnect mints a FRESH ticket.
        try await connection.reauthenticate()
        XCTAssertEqual(connection.status, .online)
        XCTAssertEqual(minter.count, 2, "re-auth mints a NEW ticket, not a silent retry")
        await connection.disconnect()
    }

    // MARK: helpers (mirror transport tests)

    static func readyFrame(replayEpoch: String = "epoch-1") -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"\#(replayEpoch)"}}}"#
    }

    static func extractID(from frame: String) -> String? {
        guard let range = frame.range(of: "\"id\":\"") else { return nil }
        let rest = frame[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func pongFrame(id: String) -> String {
        #"{"jsonrpc":"2.0","result":{"ok":true},"id":"\#(id)"}"#
    }
}
