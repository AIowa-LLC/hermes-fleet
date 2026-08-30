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

    /// Builds the H1 app-lock controller.
    ///
    /// Provider + mode selection:
    /// - Release (no launch env): real `LocalAuthenticationBiometricAuth`
    ///   with `.followSetting` mode → the persisted toggle (default ON) gates
    ///   the UI; biometrics with automatic device-passcode fallback.
    /// - DEBUG: scripted auth driven by `HERMES_FLEET_APP_LOCK` /
    ///   `HERMES_FLEET_LOCK_AUTH` launch env so the deterministic UI suites
    ///   stay green and the H1 UI tests can force lock states deterministically.
    ///
    /// Launch-env overrides (honored in all configs so Release-only live
    /// suites can opt out):
    ///   `HERMES_FLEET_APP_LOCK` = `disabled`|`off` → never lock,
    ///                             `enabled`|`on` → always lock,
    ///                             `follow` → respect the persisted toggle.
    ///   `HERMES_FLEET_LOCK_AUTH` (DEBUG) = `success` (default), `fail`,
    ///                                       `fail-all`.
    @MainActor
    static func makeLockController() -> AppLockController {
        let env = ProcessInfo.processInfo.environment

        let mode: AppLockController.Mode
        switch env["HERMES_FLEET_APP_LOCK"] {
        case "disabled", "off", "":
            mode = .disabled
        case "enabled", "on":
            mode = .enabled
        case "follow":
            mode = .followSetting
        default:
            #if DEBUG
            // No env in DEBUG: keep the existing deterministic UI suites green
            // (they cold-launch straight into the roster). H1 UI tests opt in
            // via launch env; Release (below) enforces the persisted toggle.
            mode = .disabled
            #else
            mode = .followSetting
            #endif
        }

        // H1 test hygiene: `HERMES_FLEET_LOCK_RESET=1` clears the persisted
        // toggle so the default-ON / persistence UI tests are deterministic
        // regardless of earlier runs sharing the same simulator app container.
        if env["HERMES_FLEET_LOCK_RESET"] == "1" {
            let key = AppLockController.defaultsKey
            UserDefaults.standard.removeObject(forKey: key)
        }

        #if DEBUG
        let auth: any AppLockBiometricAuth = makeScriptedLockAuth(env)
        #else
        let auth: any AppLockBiometricAuth = LocalAuthenticationBiometricAuth()
        #endif

        return AppLockController(auth: auth, mode: mode)
    }

    #if DEBUG
    /// Scripted lock auth for deterministic H1 UI tests (DEBUG only).
    private static func makeScriptedLockAuth(
        _ env: [String: String]
    ) -> any AppLockBiometricAuth {
        switch env["HERMES_FLEET_LOCK_AUTH"] {
        case "fail":
            return ScriptedLockAuth(biometricResult: .failure, passcodeSucceeds: true)
        case "fail-all":
            return ScriptedLockAuth(biometricResult: .failure, passcodeSucceeds: false)
        default:
            return ScriptedLockAuth(biometricResult: .success, passcodeSucceeds: true)
        }
    }
    #endif

    // MARK: Production — real stores + live transports

    static func makeProductionEnvironment() -> AppEnvironment {
        // The U2 UI writes credentials here (saveCredential → KeychainCredentialStore)
        // and every authenticator reads from THIS SAME store, so a credential
        // entered in the UI reaches the live gateway (L1 fix: store split).
        let credentialStore = KeychainCredentialStore()

        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: credentialStore,
            connectionFactory: makeProbeFactory(credentialStore: credentialStore)
        )
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentialStore,
            sessionFactory: makeSessionFactory(credentialStore: credentialStore)
        )
        let sessionList: any SessionListProviding = GatewaySessionListService(
            registry: registry,
            credentials: credentialStore,
            sessionFactory: makeSessionFactory(credentialStore: credentialStore)
        )
        // The file-backed SwiftData cache doubles as the health-stats store
        // (H2): same non-secret persistence seam, one store file.
        let cacheStore = makeFileBackedCache()
        let cache: any CacheStoring = cacheStore
        let health = GatewayHealthStatsAccumulator(store: cacheStore)

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: makeConnectionFactory(
                credentialStore: credentialStore, health: health),
            conversationFactory: makeConversationFactory(credentialStore: credentialStore),
            health: health
        )
    }

    /// Real per-gateway conversation session (U3): connectivity + M5
    /// conversation + M6 replay + M4 history over ONE transport. Mirrors the
    /// connection factory; `nonisolated` so the `@Sendable` closure can build
    /// transports off the main actor.
    nonisolated private static func makeConversationFactory(
        credentialStore: any CredentialStoring
    ) -> FleetConversationFactory {
        { gateway, _ in
            let base = gateway.endpoint ?? URL(string: "http://127.0.0.1:8642")!
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore),
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
    /// strategy) + WebSocket transport + single-gateway lifecycle. Feeds the
    /// H2 connection-health accumulator from the transport's health event
    /// stream (the ONLY feed point — probe/roster/conversation transports are
    /// deliberately not fed, so short-lived probes never skew uptime or the
    /// reconnect counter).
    /// `nonisolated` so the `@Sendable` factory closures can build transports
    /// off the main actor (only `AppEnvironment` construction is main-isolated).
    nonisolated private static func makeConnectionFactory(
        credentialStore: any CredentialStoring,
        health: any ConnectionHealthAccumulating
    ) -> FleetConnectionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, credentialStore: credentialStore, health: health)
        }
    }

    /// Real probe connection used by the registry's `testConnection`.
    nonisolated private static func makeProbeFactory(
        credentialStore: any CredentialStoring
    ) -> GatewayConnectionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, credentialStore: credentialStore)
        }
    }

    /// Real roster session factory used by the union roster aggregation.
    nonisolated private static func makeSessionFactory(
        credentialStore: any CredentialStoring
    ) -> GatewayRosterSessionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, credentialStore: credentialStore)
        }
    }

    nonisolated private static func makeConnection(
        gateway: FleetGateway,
        credentialStore: any CredentialStoring,
        health: (any ConnectionHealthAccumulating)? = nil
    ) -> SingleGatewayConnection {
        let base = gateway.endpoint ?? URL(string: "http://127.0.0.1:8642")!
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore),
            configuration: makeTransportConfiguration()
        )
        if let health {
            // H2: feed the accumulator from this transport's lifecycle events
            // for the lifetime of the connection (the stream never finishes).
            let events = transport.subscribeToHealthEvents()
            let gatewayID = gateway.id
            Task { [health] in
                for await event in events {
                    await health.record(event, for: gatewayID)
                }
            }
        }
        return SingleGatewayConnection(
            gatewayID: gateway.id,
            displayName: gateway.displayName,
            endpoint: gateway.endpoint,
            transport: transport
        )
    }

    /// Transport knobs. `HERMES_FLEET_PING_INTERVAL_SECONDS` (any config)
    /// overrides the heartbeat interval so the H2 UI test can assert ping RTT
    /// deterministically on a short-lived connection (the current LAN relay
    /// drops sockets at ~30s; a 2s heartbeat renders RTT within seconds).
    /// Test-support knob only — never a product feature.
    nonisolated private static func makeTransportConfiguration() -> TransportConfiguration {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["HERMES_FLEET_PING_INTERVAL_SECONDS"], let seconds = Double(raw), seconds > 0 {
            return TransportConfiguration(
                pingInterval: .milliseconds(Int64(seconds * 1000)),
                inboundDeadline: .seconds(45),
                connectTimeout: .seconds(15),
                requestTimeout: .seconds(120)
            )
        }
        return .standard
    }

    /// Authenticator honoring the gateway's configured auth strategy
    /// (synthesis §11). Credentials (loopback + session tokens) are loaded
    /// from the SAME `CredentialStoring` the U2 UI writes via saveCredential,
    /// so a UI-entered credential actually authenticates against a live
    /// gateway (L1 fix: store split + dead ticket minter).
    nonisolated private static func makeAuthenticator(
        gateway: FleetGateway,
        credentialStore: any CredentialStoring
    ) -> any AuthenticationProviding {
        let base = gateway.endpoint ?? URL(string: "http://127.0.0.1:8642")!
        switch gateway.authConfiguration.strategy {
        case .none:
            return GatewayAuthenticator(gatewayID: gateway.id, strategy: .none)
        case .loopbackToken:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: .loopbackToken,
                credentialStore: credentialStore
            )
        case .sessionToken, .bearerToken:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: gateway.authConfiguration.strategy,
                credentialStore: credentialStore,
                baseURL: base
            )
        case .usernamePassword:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: .usernamePassword,
                credentialStore: credentialStore,
                baseURL: base
            )
        }
    }

    /// File-backed SwiftData cache in Application Support, with the store's
    /// NSFileProtectionComplete + backup-exclusion (synthesis §12). Falls back
    /// to in-memory only if the container cannot be created (cache is
    /// non-critical for U1). Also serves as the H2 health-stats store.
    private static func makeFileBackedCache() -> SwiftDataCacheStore {
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
