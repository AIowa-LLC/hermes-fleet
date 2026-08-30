import Foundation
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// Builds the concrete service graph for the app composition root.
///
/// This is the ONLY place in the app target that imports FleetNetworking and
/// wires the concrete transport/registry/roster services into the observable
/// `AppEnvironment` (behind FleetCore seams). SwiftUI never imports the
/// transport module (M0 hard guard, enforced by ModuleBoundaryTests).
///
/// DEBUG builds use the scripted fleet simulator so the U1 navigation skeleton
/// is fully walkable in the simulator without a live Hermes gateway; Release
/// builds wire real Keychain + SwiftData + live transports.
@MainActor
enum FleetServiceGraph {

    static func makeDefaultEnvironment() -> AppEnvironment {
        #if DEBUG
        return makeSimulatorEnvironment()
        #else
        return makeProductionEnvironment()
        #endif
    }

    // MARK: Production — real stores + live transports

    static func makeProductionEnvironment() -> AppEnvironment {
        let credentialStore = KeychainCredentialStore()
        let tokenStore = KeychainTokenStore()

        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: credentialStore,
            connectionFactory: makeProbeFactory(tokenStore: tokenStore)
        )
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentialStore,
            sessionFactory: makeSessionFactory(tokenStore: tokenStore)
        )
        let sessionList: any SessionListProviding = GatewaySessionListService(
            registry: registry,
            credentials: credentialStore,
            sessionFactory: makeSessionFactory(tokenStore: tokenStore)
        )
        let cache: any CacheStoring = makeFileBackedCache()

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: makeConnectionFactory(tokenStore: tokenStore),
            conversationFactory: makeConversationFactory(tokenStore: tokenStore)
        )
    }

    /// Real per-gateway conversation session (U3): connectivity + M5
    /// conversation + M6 replay + M4 history over ONE transport. Mirrors the
    /// connection factory; `nonisolated` so the `@Sendable` closure can build
    /// transports off the main actor.
    nonisolated private static func makeConversationFactory(
        tokenStore: any TokenStoring
    ) -> FleetConversationFactory {
        { gateway, _ in
            let base = gateway.endpoint ?? URL(string: "http://127.0.0.1:8642")!
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, tokenStore: tokenStore),
                configuration: .standard
            )
            return GatewayConversationSession(
                gatewayID: gateway.id,
                displayName: gateway.displayName,
                endpoint: gateway.endpoint,
                transport: transport
            )
        }
    }

    /// Real per-gateway connection: authenticator (from the gateway's auth
    /// strategy) + WebSocket transport + single-gateway lifecycle.
    /// `nonisolated` so the `@Sendable` factory closures can build transports
    /// off the main actor (only `AppEnvironment` construction is main-isolated).
    nonisolated private static func makeConnectionFactory(
        tokenStore: any TokenStoring
    ) -> FleetConnectionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, tokenStore: tokenStore)
        }
    }

    /// Real probe connection used by the registry's `testConnection`.
    nonisolated private static func makeProbeFactory(
        tokenStore: any TokenStoring
    ) -> GatewayConnectionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, tokenStore: tokenStore)
        }
    }

    /// Real roster session factory used by the union roster aggregation.
    nonisolated private static func makeSessionFactory(
        tokenStore: any TokenStoring
    ) -> GatewayRosterSessionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, tokenStore: tokenStore)
        }
    }

    nonisolated private static func makeConnection(
        gateway: FleetGateway,
        tokenStore: any TokenStoring
    ) -> SingleGatewayConnection {
        let base = gateway.endpoint ?? URL(string: "http://127.0.0.1:8642")!
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            authentication: makeAuthenticator(gateway: gateway, tokenStore: tokenStore),
            configuration: .standard
        )
        return SingleGatewayConnection(
            gatewayID: gateway.id,
            displayName: gateway.displayName,
            endpoint: gateway.endpoint,
            transport: transport
        )
    }

    /// Authenticator honoring the gateway's configured auth strategy
    /// (synthesis §11). No credential entry UI in U1 — the strategy is read
    /// from the registry entry; loopback tokens are loaded from Keychain.
    nonisolated private static func makeAuthenticator(
        gateway: FleetGateway,
        tokenStore: any TokenStoring
    ) -> any AuthenticationProviding {
        switch gateway.authConfiguration.strategy {
        case .none:
            return GatewayAuthenticator(gatewayID: gateway.id, strategy: .none)
        case .loopbackToken:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: .loopbackToken,
                tokenStore: tokenStore
            )
        case .sessionToken, .bearerToken:
            let base = gateway.endpoint ?? URL(string: "http://127.0.0.1:8642")!
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: gateway.authConfiguration.strategy,
                ticketMinter: WSTicketClient(baseURL: base, sessionToken: nil)
            )
        }
    }

    /// File-backed SwiftData cache in Application Support, with the store's
    /// NSFileProtectionComplete + backup-exclusion (synthesis §12). Falls back
    /// to in-memory only if the container cannot be created (cache is
    /// non-critical for U1).
    private static func makeFileBackedCache() -> any CacheStoring {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let storeURL = directory
            .appendingPathComponent("HermesFleetCache", isDirectory: true)
            .appendingPathComponent("cache.store")
        return (try? SwiftDataCacheStore.makeFileBacked(storeURL: storeURL))
            ?? (try! SwiftDataCacheStore.makeInMemory())
    }
}
