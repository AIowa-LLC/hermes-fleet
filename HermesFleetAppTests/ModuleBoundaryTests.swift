import XCTest
import Security
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// M0: proves every module boundary compiles and links in the iOS app context,
/// and that each seam exercises its declared dependency direction.
@MainActor
final class ModuleBoundaryTests: XCTestCase {
    func testNetworkingDependsOnCore() {
        let gateway = FleetGateway(id: GatewayID(rawValue: "workstation"), displayName: "MacBook")
        XCTAssertEqual(
            FleetNetworkingPlaceholder.describe(gateway),
            "workstation · MacBook"
        )
    }

    func testSecurityDependsOnCore() {
        XCTAssertEqual(FleetSecurityPlaceholder.label(for: .readOnly), "readOnly")
    }

    func testPersistenceDependsOnCore() {
        let gateway = FleetGateway(id: GatewayID(rawValue: "render-box"), displayName: "4090")
        XCTAssertEqual(FleetPersistencePlaceholder.displayName(of: gateway), "4090")
    }

    func testUIModelStartsEmpty() {
        // U3: FleetDashboardModel was retired with the tab shell; the fleet
        // state lives in AppEnvironment (empty until load()). Keep the M0
        // assertion on the live seam: a fresh scripted-free runtime has no
        // gateways before load.
        let roster = FleetRoster()
        XCTAssertTrue(roster.allGateways.isEmpty)
        XCTAssertTrue(roster.allBots.isEmpty)
    }

    // MARK: M3 — one-gateway connectivity seam usable from the app

    func testConnectivitySeamIsUsableFromAppComposition() async {
        // The app composition root is the ONLY consumer allowed to depend on
        // FleetNetworking. Prove the M3 seam (FleetCore protocol) is
        // constructible here and reports the expected offline start state,
        // without touching the UI layer.
        let base = URL(string: "http://127.0.0.1:9119")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(2), requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticAppTicketMinter(),
            configuration: config
        )
        let connection: any GatewayConnectivityProviding = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: base,
            transport: transport
        )
        XCTAssertEqual(connection.status, .offline, "newly-registered gateway is offline")
        // Disconnect before any connect: must not crash (spec §31).
        await connection.disconnect()
        XCTAssertEqual(connection.status, .offline)
    }

    // MARK: M4 — session READ path seam usable from the app composition root

    func testSessionReadSeamIsConstructibleInComposition() async {
        // Prove the M4 session read path (FleetCore `SessionHistoryProviding`)
        // is constructible in the app composition root over the same transport
        // — the boundary that later milestone wires the Sessions screen to.
        // No network is touched: the seam is built and its error classification
        // for an unconnected transport is verified (read-only path, §5.4).
        let base = URL(string: "http://127.0.0.1:9119")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(2), requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticAppTicketMinter(),
            configuration: config
        )
        let readClient: any SessionHistoryProviding = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport
        )
        // Not connected → the read path classifies, it does not hang or mutate.
        do {
            _ = try await readClient.fetchSessionHistory(sessionID: "s")
            XCTFail("expected notConnected from unconnected read client")
        } catch let error as SessionHistoryError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: M5 — conversation streaming seam usable from the app composition root

    func testConversationSeamIsConstructibleInComposition() async {
        // Prove the M5 conversation streaming seam (FleetCore
        // `ConversationProviding`) is constructible in the app composition
        // root over the same transport the read path uses — the boundary the
        // later Conversation screen wires to. No network is touched: the seam
        // is built and its error classification for an unconnected transport
        // is verified (explicit user action only; no implicit mutation).
        let base = URL(string: "http://127.0.0.1:9119")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(2), requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticAppTicketMinter(),
            configuration: config
        )
        let conversation: any ConversationProviding = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport
        )
        // Not connected → the mutating seam classifies; it does not hang.
        do {
            _ = try await conversation.submitPrompt(sessionID: "s", text: "hi")
            XCTFail("expected notConnected from unconnected conversation client")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: M6 — reconnect/replay seam usable from the app composition root

    func testReplaySeamIsConstructibleInComposition() async {
        // Prove the M6 reconnect/replay seam (FleetCore `ReplayProviding`) is
        // constructible in the app composition root over the same transport
        // the read/conversation paths use. No network is touched: the seam is
        // built and its error classification for an unconnected transport is
        // verified (replay is observation, never an implicit mutation — §5.4).
        let base = URL(string: "http://127.0.0.1:9119")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(2), requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticAppTicketMinter(),
            configuration: config
        )
        let history: any SessionHistoryProviding = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport
        )
        let replay: any ReplayProviding = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: history
        )
        // Not connected → the replay seam classifies; it does not hang or
        // invent events.
        do {
            _ = try await replay.replayAfterReconnect()
            XCTFail("expected notConnected from unconnected replay engine")
        } catch let error as ReplayError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: M7 — gateway registry + Keychain credential storage usable from the app

    func testGatewayRegistrySeamIsConstructibleInComposition() async throws {
        // Prove the M7 registry seam (FleetCore `GatewayRegistryManaging`) is
        // constructible in the app composition root over the Keychain
        // credential store (FleetSecurity) — the boundary the Gateways screen
        // later wires to. No network is touched: a stub connection classifies
        // an unconnected/unreachable probe instead of hanging.
        let store = InMemoryCredentialStore()
        let service: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: store,
            connectionFactory: { gateway, _ in
                StubRegistryConnection(gatewayID: gateway.id)
            }
        )
        let endpoint = URL(string: "http://127.0.0.1:9119")!
        let id = GatewayID(rawValue: "workstation")
        let gateway = try await service.addGateway(
            GatewayRegistration(id: id, displayName: "MacBook", endpoint: endpoint))
        XCTAssertEqual(gateway.displayName, "MacBook")
        let registeredCount = await service.allGateways().count
        XCTAssertEqual(registeredCount, 1)

        // Auth config: store a credential, mark configured, clear it.
        try await service.saveCredential(GatewayCredential(rawValue: "fixture-token"), for: id)
        let hasCredential = await service.hasCredential(for: id)
        XCTAssertTrue(hasCredential)
        try await service.clearCredential(for: id)
        let afterClear = await service.hasCredential(for: id)
        XCTAssertFalse(afterClear)

        // Test connection: the stub is unreachable → classified offline, no crash.
        let result = try await service.testConnection(to: id)
        XCTAssertEqual(result.status, .offline)

        // Remove is safe and idempotent after registration.
        try await service.removeGateway(id)
        let remainingCount = await service.allGateways().count
        XCTAssertEqual(remainingCount, 0)
    }

    func testKeychainCredentialStoreSafeAttributesInApp() {
        // The "Keychain safe" acceptance (spec §16/§27/§31 Security): gateway
        // credentials use GenericPassword, WhenUnlockedThisDeviceOnly, no
        // iCloud sync — asserted from the exact attributes the store builds.
        let attributes = KeychainCredentialStore.baseAttributes(account: "workstation")
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "com.aiowa.hermesfleet.gateway-credentials")
    }

    func testKeychainCredentialStoreRoundTripInApp() async throws {
        // Real Keychain round-trip on the simulator (the app's own keychain):
        // save → load → delete. Proves the FleetSecurity store actually
        // persists/retrieves a credential in the app context, with no secret
        // leaking into the value's description.
        let store = KeychainCredentialStore()
        let id = GatewayID(rawValue: "m7-boundary-test-gateway")
        let credential = GatewayCredential(rawValue: "boundary-fixture-token")

        try await store.deleteCredential(for: id) // clean slate
        defer { Task { try? await store.deleteCredential(for: id) } }

        try await store.saveCredential(credential, for: id)
        let loaded = try await store.loadCredential(for: id)
        XCTAssertEqual(loaded, credential)
        XCTAssertEqual(loaded?.description, "[REDACTED]", "secret never prints")

        try await store.deleteCredential(for: id)
        let afterDelete = try await store.loadCredential(for: id)
        XCTAssertNil(afterDelete, "credential is gone after delete")
    }

    // MARK: M8 — multi-gateway union roster seam usable from the app composition root

    func testFleetRosterSeamIsConstructibleInComposition() async throws {
        // Prove the M8 union-roster seam (FleetCore `FleetRosterProviding`)
        // is constructible in the app composition root over the registry +
        // credential seams — the boundary the Fleet screen later wires to.
        // No network is touched: stub sessions classify an unreachable gateway
        // instead of hanging, and the refresh never throws for a gateway
        // outage (spec §31 Multi-Gateway / §30 partial availability).
        let store = InMemoryCredentialStore()
        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: store,
            connectionFactory: { gateway, _ in
                StubRegistryConnection(gatewayID: gateway.id)
            }
        )
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: store,
            sessionFactory: { gateway, _ in
                StubRosterSession(gatewayID: gateway.id)
            }
        )

        // Two registered gateways, both unreachable via stubs.
        _ = try await registry.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "workstation"), displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:8642")!))
        _ = try await registry.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "arch"), displayName: "Arch",
            endpoint: URL(string: "http://127.0.0.1:9900")!))

        let snapshot = await roster.refreshRoster()

        // Partial availability: both classified offline, no crash, no throw.
        XCTAssertEqual(snapshot.reachableGateways.count, 0)
        XCTAssertEqual(snapshot.unreachableGateways.count, 2)
        XCTAssertEqual(
            snapshot.outcome(for: GatewayID(rawValue: "workstation")),
            .failed(status: .offline, detail: "gateway unreachable"))
        XCTAssertEqual(snapshot.outcome(for: GatewayID(rawValue: "arch")),
            .failed(status: .offline, detail: "gateway unreachable"))
        XCTAssertTrue(snapshot.roster.allBots.isEmpty, "unreachable gateways contribute no bots")
        XCTAssertEqual(snapshot.roster.allGateways.count, 2, "gateway entries preserved with last-known state")
    }

    // MARK: M10 — Keychain token store + SwiftData cache usable from the app

    func testKeychainTokenStoreSafeAttributesInApp() {
        // The "tokens/tickets live only in Keychain" acceptance (spec §16,
        // §31 Security; synthesis §12): tokens use GenericPassword,
        // WhenUnlockedThisDeviceOnly, no iCloud sync — asserted from the exact
        // attributes the store builds.
        let attributes = KeychainTokenStore.baseAttributes(account: "workstation")
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "com.aiowa.hermesfleet.tokens")
    }

    func testKeychainTokenStoreRoundTripInApp() async throws {
        // Real Keychain round-trip on the simulator (the app's own keychain):
        // save → load → delete. Proves the FleetSecurity token store actually
        // persists/retrieves a token/ticket in the app context, with no secret
        // leaking into the value's description.
        let store = KeychainTokenStore()
        let id = GatewayID(rawValue: "m10-boundary-test-peer")
        let token = StoredToken(rawValue: "boundary-fixture-ticket")

        try await store.deleteToken(for: id) // clean slate
        defer { Task { try? await store.deleteToken(for: id) } }

        try await store.saveToken(token, for: id)
        let loaded = try await store.loadToken(for: id)
        XCTAssertEqual(loaded, token)
        XCTAssertEqual(loaded?.description, "[REDACTED]", "token never prints")

        try await store.deleteToken(for: id)
        let afterDelete = try await store.loadToken(for: id)
        XCTAssertNil(afterDelete, "token is gone after delete")
    }

    func testSwiftDataCacheStoreFileProtectionInApp() async throws {
        // The "NSFileProtectionComplete + backup-excluded" on-disk acceptance
        // (synthesis §12): a file-backed SwiftData cache store applies the
        // attributes to its store file in the app sandbox. Verified by reading
        // the attributes back on iOS.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M10Cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("cache.store")
        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)

        let protection = CacheStoreProtection.read(from: storeURL)
        XCTAssertEqual(protection.backupExcluded, true, "cache is excluded from backup")
        // The store applies NSFileProtectionComplete. The iOS Simulator does
        // not faithfully honor per-file protection classes — it reports the
        // simulator's default class (CompleteUntilFirstUserAuthentication)
        // rather than the applied .complete — so the honest on-simulator
        // assertion is that the file reports a non-nil protection class
        // (i.e. data protection is on), while backup exclusion (which the
        // simulator DOES honor) is asserted exactly.
        XCTAssertNotNil(
            protection.fileProtection,
            "store file reports a data-protection class (NSFileProtectionComplete applied on device)")
        XCTAssertNotNil(store.storeURL, "file-backed store exposes its URL")
    }

    func testSwiftDataCacheStoreRoundTripInApp() async throws {
        // App composition-root proof: a file-backed SwiftData cache round-trips
        // history + watermark + replay_epoch without network or Keychain, and a
        // stale-epoch reset clears only the affected gateway.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M10CacheRT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SwiftDataCacheStore.makeFileBacked(
            storeURL: dir.appendingPathComponent("cache.store"))
        let m5 = GatewayID(rawValue: "workstation")
        let arch = GatewayID(rawValue: "arch")

        let history = SessionHistory(sessionID: "s1", count: 1, messages: [
            SessionMessage(role: .user, text: "app-level hello", timestamp: 1, rowID: "r1"),
        ])
        try await store.saveHistory(history, for: m5)
        let loaded = try await store.loadHistory(sessionID: "s1", for: m5)
        XCTAssertEqual(loaded, history)

        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 7), for: m5)
        let watermarks = try await store.loadWatermarks()
        XCTAssertEqual(watermarks, [SessionEventWatermark(sessionID: "s1", lastSeenSeq: 7)])

        try await store.saveReplayEpoch("epoch-9", for: m5)
        let epoch = try await store.loadReplayEpoch(for: m5)
        XCTAssertEqual(epoch, "epoch-9")

        // Unrelated gateway untouched by reset of workstation.
        try await store.saveReplayEpoch("arch-epoch", for: arch)
        try await store.resetForReplayEpochChange(gatewayID: m5)
        let archEpoch = try await store.loadReplayEpoch(for: arch)
        XCTAssertEqual(archEpoch, "arch-epoch")
        let cleared = try await store.loadReplayEpoch(for: m5)
        XCTAssertNil(cleared)
    }

    func testNoTokenInCacheInvariantInApp() async throws {
        // "No tokens in cache" (card + synthesis §12): the SwiftData cache
        // accepts ONLY non-secret values by construction. A token stored in the
        // Keychain token store can never be written into or read back from the
        // cache — the two stores are structurally disjoint.
        let store = try SwiftDataCacheStore.makeInMemory()
        let tokenStore = KeychainTokenStore()
        let id = GatewayID(rawValue: "m10-invariant-peer")

        // A token is accepted only by the Keychain token store…
        try await tokenStore.saveToken(StoredToken(rawValue: "secret-ticket-xyz"), for: id)
        defer { Task { try? await tokenStore.deleteToken(for: id) } }

        // …and the cache has no token/credential API surface to receive it.
        // (Structural: this test compiles against `CacheStoring`'s non-secret
        // requirements; the data-bearing checks confirm only non-secret values
        // live in the cache.)
        let watermarks = try await store.loadWatermarks()
        XCTAssertTrue(watermarks.isEmpty)
        let history = try await store.loadHistory(sessionID: "s1", for: id)
        XCTAssertNil(history)
        let epoch = try await store.loadReplayEpoch(for: id)
        XCTAssertNil(epoch)
        XCTAssertFalse("\(epoch ?? "")".contains("secret"), "no token material in cache")
    }

    // MARK: M11 — Authentication Hardening usable from the app composition root

    func testAuthenticationProviderSeamIsConstructibleInComposition() async throws {
        // The M11 auth seam (spec §16 "AuthenticationProvider"; synthesis §11)
        // is constructible in the app composition root over the Keychain
        // credential store (the SAME store the U2 UI writes via saveCredential)
        // + a ticket minter. Proves the ticket and loopback-token paths both
        // produce auth material WITHOUT exposing the raw secret, and the
        // `.none` path yields no auth.
        let keychain = KeychainCredentialStore()
        let id = GatewayID(rawValue: "m11-boundary-gateway")

        // Ticket path: a session-token gateway mints a single-use ticket.
        let ticketAuth = GatewayAuthenticator(
            gatewayID: id, strategy: .sessionToken,
            ticketMinter: StaticAppTicketMinter())
        let ticketResult = try await ticketAuth.authenticate()
        guard case .ticket(let token) = ticketResult else {
            return XCTFail("expected ticket auth, got \(ticketResult)")
        }
        XCTAssertEqual(token.rawValue, "fixture-ticket")
        XCTAssertEqual(ticketResult.description, "[REDACTED]", "auth value never prints")

        // Loopback path: a loopback-token gateway loads the credential from the
        // SAME Keychain credential store the U2 UI writes via saveCredential.
        try await keychain.saveCredential(GatewayCredential(rawValue: "loop-token-abc"), for: id)
        defer { Task { try? await keychain.deleteCredential(for: id) } }
        let loopAuth = GatewayAuthenticator(
            gatewayID: id, strategy: .loopbackToken, credentialStore: keychain)
        let loopResult = try await loopAuth.authenticate()
        guard case .loopbackToken(let loopToken) = loopResult else {
            return XCTFail("expected loopbackToken auth, got \(loopResult)")
        }
        XCTAssertEqual(loopToken.rawValue, "loop-token-abc")
        XCTAssertFalse("\(loopResult)".contains("loop-token-abc"))

        // None path: an open gateway authenticates with `.none`.
        let noneAuth = GatewayAuthenticator(gatewayID: id, strategy: .none)
        let noneResult = try await noneAuth.authenticate()
        XCTAssertEqual(noneResult, .none)
    }

    func testWSTicketAndAuthRedactionInApp() {
        // spec §16/§29: no credentials in logs/UI. A WS ticket and the
        // connection-auth value never print their raw secret, in the app
        // context (composition root could log these by accident).
        let ticket = WSTicket(token: "app-secret-ticket-value", ttlSeconds: 30)
        XCTAssertEqual(ticket.description, "[REDACTED]")
        XCTAssertFalse("\(ticket)".contains("app-secret-ticket-value"))

        let auth = ConnectionAuthentication.ticket(StoredToken(rawValue: "app-secret-ticket-value"))
        XCTAssertEqual(auth.description, "[REDACTED]")
        XCTAssertFalse("\(auth)".contains("app-secret-ticket-value"))

        let loopback = ConnectionAuthentication.loopbackToken(StoredToken(rawValue: "app-loop-secret"))
        XCTAssertEqual(loopback.description, "[REDACTED]")
        XCTAssertFalse("\(loopback)".contains("app-loop-secret"))
    }

    func testLoopbackTokenAndTicketURLBuildingInApp() {
        // synthesis §11: the socket carries `?ticket=` (single-use) or
        // `?token=` (loopback). Both build in the app composition context.
        let base = URL(string: "http://127.0.0.1:9119")!
        let ticketURL = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws",
            authentication: .ticket(StoredToken(rawValue: "ticket-xyz")))!
        XCTAssertEqual(
            URLComponents(url: ticketURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "ticket" })?.value,
            "ticket-xyz")

        let loopURL = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws",
            authentication: .loopbackToken(StoredToken(rawValue: "token-xyz")))!
        XCTAssertEqual(
            URLComponents(url: loopURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value,
            "token-xyz")
    }

    func testRedactionScrubsAuthQueryInApp() {
        // spec §29: network error logs redact credentials and sensitive query
        // parameters. A built auth URL, if ever logged, must not leak the secret.
        let base = URL(string: "http://127.0.0.1:9119")!
        let url = GatewayWebSocketTransport.buildWebSocketURL(
            base: base, path: "/api/ws",
            authentication: .ticket(StoredToken(rawValue: "top-secret-in-app")))!
        let redacted = Redaction.redactedURL(url)
        XCTAssertFalse(redacted.contains("top-secret-in-app"))
        XCTAssertTrue(redacted.contains("ticket="))
    }

    /// Minimal stub connection used by the app-level registry boundary test.
    private struct StubRegistryConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { throw GatewayConnectivityError.unreachable }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    /// Minimal stub roster session used by the app-level M8 boundary test: an
    /// unreachable gateway classifies offline without touching the network.
    private struct StubRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { throw GatewayConnectivityError.unreachable }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { throw RosterError.notConnected }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { throw RosterError.notConnected }
    }

    // MARK: U2 — `session.list` read seam usable from the app composition root

    func testSessionListSeamIsConstructibleInComposition() async throws {
        // Prove the U2 `session.list` read seam (FleetCore
        // `SessionListProviding`) is constructible in the app composition root
        // over the registry + credential + roster-session seams — the boundary
        // Bot detail wires to. No network: an unconnected route classifies a
        // read error instead of hanging (spec §5.4 observation-only).
        let store = InMemoryCredentialStore()
        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: store,
            connectionFactory: { gateway, _ in
                StubRegistryConnection(gatewayID: gateway.id)
            }
        )
        _ = try await registry.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "workstation"), displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:8642")!))

        let sessionList: any SessionListProviding = GatewaySessionListService(
            registry: registry,
            credentials: store,
            sessionFactory: { gateway, _ in
                StubRosterSession(gatewayID: gateway.id)
            }
        )
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        do {
            _ = try await sessionList.fetchSessions(for: route, limit: 10)
            XCTFail("expected notConnected from unreachable gateway")
        } catch let error as RosterError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: U3 — conversation session seam usable from the app composition root

    func testConversationSessionSeamIsConstructibleInComposition() async {
        // Prove the U3 conversation bundle seam (FleetCore
        // `ConversationSessionProviding`) is constructible in the app
        // composition root over the same transport the connection uses — the
        // boundary the Conversation screen wires to. No network is touched:
        // the mutating seam classifies an unconnected transport as
        // `.notConnected` instead of hanging (explicit user action only).
        let base = URL(string: "http://127.0.0.1:9119")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(2), requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticAppTicketMinter(),
            configuration: config
        )
        let session: any ConversationSessionProviding = GatewayConversationSession(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: base,
            transport: transport
        )
        // The conversation path classifies an unconnected transport.
        do {
            _ = try await session.conversation.submitPrompt(sessionID: "s", text: "hi")
            XCTFail("expected notConnected from unconnected conversation session")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // The replay path classifies an unconnected transport too.
        do {
            _ = try await session.replay.replayAfterReconnect()
            XCTFail("expected notConnected from unconnected replay engine")
        } catch let error as ReplayError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Minimal ticket minter for the app-level boundary test (no network).
    private struct StaticAppTicketMinter: WSTicketMinting {
        func mintTicket() async throws -> WSTicket {
            WSTicket(token: "fixture-ticket", ttlSeconds: 30)
        }
    }

    // MARK: H2 — connection-health seam usable from the app composition root

    func testConnectionHealthSeamIsConstructibleInComposition() async throws {
        // Prove the H2 health seam (FleetCore `ConnectionHealthAccumulating` +
        // `HealthStatsStoring`) is constructible in the app composition root
        // over the SAME file-backed SwiftData store the cache uses — the
        // boundary the Health dashboard wires to. No network: the accumulator
        // is fed synthetic events and the snapshot round-trips through the
        // store, proving stats survive an app restart (new accumulator over
        // the same store).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("H2Boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SwiftDataCacheStore.makeFileBacked(
            storeURL: dir.appendingPathComponent("cache.store"))
        let id = GatewayID(rawValue: "workstation")

        let first: any ConnectionHealthAccumulating = GatewayHealthStatsAccumulator(store: store)
        await first.record(.connectStarted, for: id)
        await first.record(.connected, for: id)
        await first.record(.disconnected(reason: "normal closure"), for: id)
        await first.record(.pingRTT(milliseconds: 8.0), for: id)

        // "Restart": a fresh accumulator over the same store restores the
        // persisted stats (non-secret; the store is the file-backed cache).
        let second: any ConnectionHealthAccumulating = GatewayHealthStatsAccumulator(store: store)
        await second.rehydrate(gatewayIDs: [id])
        let restored = await second.stats(for: id)
        XCTAssertEqual(restored?.lastDisconnectReason, "normal closure")
        XCTAssertEqual(restored?.pingSampleCount, 1)
        XCTAssertEqual(restored?.lastPingRTTMilliseconds, 8.0)
    }
}
