import Foundation
import FleetCore

/// Builds a single-gateway connection for a registered gateway, so the
/// registry service can probe reachability + capability surface without
/// depending on transport construction itself. Injected at the composition
/// root (app target) — keeps `GatewayRegistryService` free of concrete
/// transport wiring and lets tests inject in-process-server connections.
public typealias GatewayConnectionFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any GatewayConnectivityProviding

/// Concrete `GatewayRegistryManaging` — the M7 Gateway Registry service.
///
/// Owns the in-memory `GatewayRegistry` (M2), stores credentials through the
/// injected `CredentialStoring` seam (Keychain in production, in-memory in
/// tests), and probes connectivity through the injected `GatewayConnectionFactory`.
///
/// Responsibilities (spec §15.2 Gateways / §31 Gateway / §12 model):
/// - add / edit / remove gateways;
/// - authenticate (store/clear credentials — Keychain-safe, never logged);
/// - test connection (reachable/unreachable probe + capability surface);
/// - lookup fails closed (nil / `.notFound` for unknown IDs).
///
/// No live Hermes gateway is required to construct this service; tests drive
/// it with in-process fixture servers (consistent with M1–M6).
public actor GatewayRegistryService: GatewayRegistryManaging {
    private var registry: GatewayRegistry
    private let credentials: any CredentialStoring
    private let connectionFactory: GatewayConnectionFactory

    public init(
        registry: GatewayRegistry = GatewayRegistry(),
        credentials: any CredentialStoring,
        connectionFactory: @escaping GatewayConnectionFactory
    ) {
        self.registry = registry
        self.credentials = credentials
        self.connectionFactory = connectionFactory
    }

    // MARK: GatewayRegistryManaging

    public func allGateways() async -> [FleetGateway] {
        registry.allGateways
    }

    public func gateway(for id: GatewayID) async -> FleetGateway? {
        registry.gateway(for: id)
    }

    public func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        // Fail closed on invalid input before mutating anything.
        let displayName = registration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw GatewayRegistryError.emptyDisplayName
        }
        guard let scheme = registration.endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw GatewayRegistryError.invalidEndpoint
        }
        let id = registration.id ?? GatewayID(endpoint: registration.endpoint)
        // M9 fail-closed guard: an unsafe gateway ID (path traversal, `#`,
        // separators) is rejected before registration — it must never become
        // the identity half of a route or a Keychain key.
        guard id.isRoutingSafe else {
            throw GatewayRegistryError.invalidGatewayID(id.rawValue)
        }
        guard registry.gateway(for: id) == nil else {
            throw GatewayRegistryError.duplicate(id)
        }
        let gateway = FleetGateway(
            id: id,
            displayName: displayName,
            endpoint: registration.endpoint,
            authConfiguration: registration.authConfiguration
        )
        registry.register(gateway)
        return gateway
    }

    public func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        if let endpoint = edits.endpoint {
            guard let scheme = endpoint.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw GatewayRegistryError.invalidEndpoint
            }
        }
        registry.update(id) { gateway in
            let updated = edits.applied(to: gateway)
            gateway = updated
        }
        guard let updated = registry.gateway(for: id) else {
            throw GatewayRegistryError.notFound(id)
        }
        return updated
    }

    public func removeGateway(_ id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        registry.remove(id)
        // Best-effort credential cleanup (Keychain-safe; missing is a no-op).
        try? await credentials.deleteCredential(for: id)
    }

    public func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        do {
            try await credentials.saveCredential(credential, for: id)
        } catch {
            throw GatewayRegistryError.credentialStoreFailed(String(describing: error))
        }
        registry.update(id) { gateway in
            gateway.authConfigured = true
            // Preserve the gateway's configured strategy (set by the U2 UI via
            // addGateway registration / updateGateway) — never force-override it.
            // L1 finding #2: force-overriding to .sessionToken here made every
            // UI-selected strategy (e.g. loopback) unreachable.
            gateway.authConfiguration = GatewayAuthConfiguration(
                strategy: gateway.authConfiguration.strategy,
                credentialStored: true
            )
        }
    }

    public func clearCredential(for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        try? await credentials.deleteCredential(for: id)
        registry.update(id) { gateway in
            gateway.authConfigured = false
            gateway.authConfiguration = .none
        }
    }

    public func hasCredential(for id: GatewayID) async -> Bool {
        (try? await credentials.loadCredential(for: id)) != nil
    }

    public func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
        guard let gateway = registry.gateway(for: id) else {
            throw GatewayRegistryError.notFound(id)
        }
        let credential = try? await credentials.loadCredential(for: id)
        let connection = connectionFactory(gateway, credential)

        let result: GatewayTestResult
        do {
            try await connection.connect()
            let adopted = await connection.adoptedReady()
            // Reflect adopted metadata into the registry entry (capability
            // surface + auth status) — server state is authoritative (spec §5.3).
            registry.update(id) { entry in
                entry.connectionState = .connected
                entry.capabilities = adopted?.capabilities ?? []
                entry.replayEpoch = adopted?.replayEpoch
                entry.authConfigured = credential != nil
            }
            result = GatewayTestResult(
                status: connection.status,
                capabilities: GatewayCapabilities(strings: adopted?.capabilities ?? []),
                serverIdentity: gateway.serverIdentity
            )
        } catch let error as GatewayConnectivityError {
            let status = GatewayStatus(connectivityError: error)
            registry.update(id) { entry in
                entry.connectionState = .failed(status.rawValue)
            }
            result = GatewayTestResult(status: status)
        } catch {
            let status = GatewayStatus.offline
            registry.update(id) { entry in
                entry.connectionState = .failed("\(error)")
            }
            result = GatewayTestResult(status: status)
        }

        // ADR #3 — the probe ALWAYS tears down its connection before
        // returning: `disconnect()` is idempotent and safe from every state
        // (spec §31 "disconnect does not crash"), so this single await covers
        // the success path and every classified-failure path alike. Without
        // it, the probe's WebSocket socket + receive/heartbeat tasks are
        // abandoned after a successful test.
        await connection.disconnect()
        return result
    }
}
