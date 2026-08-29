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
        let gateway = FleetGateway(id: GatewayID(rawValue: "<dev-workstation>"), displayName: "MacBook")
        XCTAssertEqual(
            FleetNetworkingPlaceholder.describe(gateway),
            "<dev-workstation> · MacBook"
        )
    }

    func testSecurityDependsOnCore() {
        XCTAssertEqual(FleetSecurityPlaceholder.label(for: .readOnly), "readOnly")
    }

    func testPersistenceDependsOnCore() {
        let gateway = FleetGateway(id: GatewayID(rawValue: "gaming-4090"), displayName: "4090")
        XCTAssertEqual(FleetPersistencePlaceholder.displayName(of: gateway), "4090")
    }

    func testUIModelStartsEmpty() {
        let model = FleetDashboardModel()
        XCTAssertTrue(model.gateways.isEmpty)
        XCTAssertFalse(model.isLoading)
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            transport: transport
        )
        let replay: any ReplayProviding = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
        let id = GatewayID(rawValue: "<dev-workstation>")
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
        let attributes = KeychainCredentialStore.baseAttributes(account: "<dev-workstation>")
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "<legacy-personal-bundle-id>.gateway-credentials")
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

    /// Minimal ticket minter for the app-level boundary test (no network).
    private struct StaticAppTicketMinter: WSTicketMinting {
        func mintTicket() async throws -> WSTicket {
            WSTicket(token: "fixture-ticket", ttlSeconds: 30)
        }
    }
}
