import Foundation
import FleetCore
import os

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
public actor GatewayRegistryService: GatewayRegistryManaging, GatewayPairingRegistering {
    private var registry: GatewayRegistry
    private let credentials: any CredentialStoring
    private let connectionFactory: GatewayConnectionFactory
    /// P0-4: durable non-secret gateway-record store. Every durable mutation
    /// writes through immediately; `nil` (scripted fleet / tests) keeps the
    /// registry purely in-memory, exactly as before.
    private let recordStore: (any GatewayRecordStoring)?
    /// T3: per-gateway TLS pin store (TOFU SPKI pinning). `nil` keeps the
    /// registry pin-unaware (scripted fleet / legacy tests).
    private let pinStore: (any TLSPinStoring)?
    /// Clears endpoint-scoped owner-enrollment retry secrets and temporary
    /// pin aliases on removal. Optional for legacy/scripted registries.
    private let enrollmentCleanup: (any GatewayEnrollmentCleanupProviding)?

    /// In-flight pairing registrations reserve both the stable gateway ID and
    /// endpoint before the first suspension point. The configured record is
    /// written last and is the durable commit marker.
    private struct PairingReservation {
        let grant: PairingGrant
        let gateway: FleetGateway
        var credentialWriteAttempted = false
        var pinWriteAttempted = false
        var recordWriteAttempted = false
        var registrationInProgress = true
        var cleanupInProgress = false
    }
    private var pairingReservations: [GatewayID: PairingReservation] = [:]

    public init(
        registry: GatewayRegistry = GatewayRegistry(),
        credentials: any CredentialStoring,
        connectionFactory: @escaping GatewayConnectionFactory,
        recordStore: (any GatewayRecordStoring)? = nil,
        pinStore: (any TLSPinStoring)? = nil,
        enrollmentCleanup: (any GatewayEnrollmentCleanupProviding)? = nil
    ) {
        self.registry = registry
        self.credentials = credentials
        self.connectionFactory = connectionFactory
        self.recordStore = recordStore
        self.pinStore = pinStore
        self.enrollmentCleanup = enrollmentCleanup
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
        // P1-6: treat the endpoint as an ORIGIN — reject user-info, strip
        // query/fragment at the registry boundary before anything is stored,
        // displayed, or logged.
        let endpoint = try GatewayEndpoint.normalizedOrigin(from: registration.endpoint)
        let id = registration.id ?? GatewayID(endpoint: endpoint)
        // M9 fail-closed guard: an unsafe gateway ID (path traversal, `#`,
        // separators) is rejected before registration — it must never become
        // the identity half of a route or a Keychain key.
        guard id.isRoutingSafe else {
            throw GatewayRegistryError.invalidGatewayID(id.rawValue)
        }
        guard registry.gateway(for: id) == nil,
              !pairingReservations.values.contains(where: {
                  $0.gateway.id == id || Self.sameOrigin($0.gateway.endpoint, endpoint)
              }) else {
            throw GatewayRegistryError.duplicate(id)
        }
        let gateway = FleetGateway(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            authConfiguration: registration.authConfiguration
        )
        registry.register(gateway)
        // P0-4: persist IMMEDIATELY on Add — the record survives app close /
        // relaunch regardless of connection state. A persistence failure must
        // surface (never silently drop the user's entry); the in-memory
        // registration is rolled back so the UI state and the store agree.
        do {
            try await persist(gateway)
        } catch {
            registry.remove(id)
            throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
        }
        return gateway
    }

    // MARK: Atomic pairing registration

    /// Commit a paired gateway only after its device credential and confirmed
    /// SPKI pin are secured. The durable configured record is written last;
    /// it is never possible for restore to observe a just-added unauthenticated
    /// pairing row.
    public func registerPairedGateway(_ grant: PairingGrant) async throws -> FleetGateway {
        guard let id = GatewayID(pairedInstanceID: grant.gateway.instanceID), id.isRoutingSafe else {
            throw GatewayRegistryError.invalidGatewayID(grant.gateway.instanceID)
        }
        guard Self.isValidDeviceCredential(grant.credential.rawValue, deviceID: grant.deviceID) else {
            throw GatewayRegistryError.credentialStoreFailed("invalid paired credential")
        }
        let endpoint = try GatewayEndpoint.normalizedOrigin(from: grant.gateway.origin)
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.path.isEmpty || endpoint.path == "/" else {
            throw GatewayRegistryError.invalidEndpoint
        }
        guard let pinStore else {
            throw GatewayRegistryError.pinStoreFailed("pin store unavailable")
        }
        guard let recordStore else {
            throw GatewayRegistryError.recordStoreFailed("record store unavailable")
        }
        let displayName = grant.gateway.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { throw GatewayRegistryError.emptyDisplayName }

        guard registry.gateway(for: id) == nil,
              !registry.allGateways.contains(where: { Self.sameOrigin($0.endpoint, endpoint) }),
              !pairingReservations.values.contains(where: {
                  $0.gateway.id == id || Self.sameOrigin($0.gateway.endpoint, endpoint)
              }) else {
            throw GatewayRegistryError.duplicate(id)
        }

        let gateway = FleetGateway(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            authConfigured: true,
            authConfiguration: GatewayAuthConfiguration(strategy: .deviceCredential, credentialStored: true)
        )
        pairingReservations[id] = PairingReservation(grant: grant, gateway: gateway)

        // All storage reads happen under the reservation so an actor-reentrant
        // Add or another pairing transaction cannot claim the same identity.
        let records: [StoredGatewayRecord]
        do { records = try await recordStore.loadGatewayRecords() }
        catch {
            pairingReservations.removeValue(forKey: id)
            throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
        }
        guard !records.contains(where: { record in
            record.id == id.rawValue || Self.sameOrigin(URL(string: record.endpoint), endpoint)
        }) else {
            pairingReservations.removeValue(forKey: id)
            throw GatewayRegistryError.duplicate(id)
        }
        do {
            guard try await credentials.loadCredential(for: id) == nil else {
                pairingReservations.removeValue(forKey: id)
                throw GatewayRegistryError.duplicate(id)
            }
        } catch {
            pairingReservations.removeValue(forKey: id)
            if let registryError = error as? GatewayRegistryError { throw registryError }
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
        }
        do {
            if let existingPin = try await pinStore.loadPin(for: id), existingPin != grant.tlsFingerprint {
                pairingReservations.removeValue(forKey: id)
                throw GatewayRegistryError.pinStoreFailed("gateway key changed")
            }
        } catch {
            pairingReservations.removeValue(forKey: id)
            if let registryError = error as? GatewayRegistryError { throw registryError }
            throw GatewayRegistryError.pinStoreFailed(Redaction.safeErrorDescription(error))
        }

        // Each attempted write is marked before its await because a store may
        // persist successfully and then report an error. Discard is therefore
        // safe even for an ambiguous write result.
        pairingReservations[id]?.credentialWriteAttempted = true
        do {
            try await credentials.saveCredential(
                GatewayCredential(rawValue: grant.credential.rawValue), for: id)
        } catch {
            pairingReservations[id]?.registrationInProgress = false
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
        }

        do {
            let existingPin = try await pinStore.loadPin(for: id)
            if let existingPin {
                guard existingPin == grant.tlsFingerprint else {
                    throw GatewayRegistryError.pinStoreFailed("gateway key changed")
                }
            } else {
                pairingReservations[id]?.pinWriteAttempted = true
                try await pinStore.savePin(grant.tlsFingerprint, for: id)
            }
        } catch {
            pairingReservations[id]?.registrationInProgress = false
            if let registryError = error as? GatewayRegistryError { throw registryError }
            throw GatewayRegistryError.pinStoreFailed(Redaction.safeErrorDescription(error))
        }

        // Commit marker last. If this throws after writing, discard removes
        // this transaction's record before touching its secure material.
        pairingReservations[id]?.recordWriteAttempted = true
        do {
            try await recordStore.saveGatewayRecord(StoredGatewayRecord(
                id: id.rawValue,
                displayName: gateway.displayName,
                endpoint: endpoint.absoluteString,
                authConfiguration: gateway.authConfiguration,
                authConfigured: true
            ))
        } catch {
            pairingReservations[id]?.registrationInProgress = false
            throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
        }

        registry.register(gateway)
        pairingReservations.removeValue(forKey: id)
        return gateway
    }

    /// Remove only material written by an incomplete pairing transaction.
    /// A committed gateway has no reservation and is therefore untouchable.
    public func discardUncommittedPairing(_ grant: PairingGrant) async throws {
        guard let id = GatewayID(pairedInstanceID: grant.gateway.instanceID),
              var reservation = pairingReservations[id], reservation.grant == grant else { return }
        guard !reservation.registrationInProgress else {
            throw GatewayRegistryError.credentialStoreFailed("pairing registration still in progress")
        }
        guard !reservation.cleanupInProgress else {
            throw GatewayRegistryError.credentialStoreFailed("pairing cleanup already in progress")
        }
        reservation.cleanupInProgress = true
        pairingReservations[id] = reservation

        // Remove the possible commit marker first. If it cannot be removed,
        // retain the credential and pin for a safe retry rather than allowing
        // a stale durable row to restore without its trust material.
        if reservation.recordWriteAttempted, let recordStore {
            do {
                try await recordStore.deleteGatewayRecord(id: id)
                pairingReservations[id]?.recordWriteAttempted = false
            } catch {
                pairingReservations[id]?.cleanupInProgress = false
                throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        if reservation.credentialWriteAttempted {
            do {
                try await credentials.deleteCredential(for: id)
                pairingReservations[id]?.credentialWriteAttempted = false
            } catch {
                pairingReservations[id]?.cleanupInProgress = false
                throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        if reservation.pinWriteAttempted, let pinStore {
            do {
                try await pinStore.deletePin(for: id)
                pairingReservations[id]?.pinWriteAttempted = false
            } catch {
                pairingReservations[id]?.cleanupInProgress = false
                throw GatewayRegistryError.pinStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        pairingReservations.removeValue(forKey: id)
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs, let a = try? GatewayEndpoint.normalizedOrigin(from: lhs),
              let b = try? GatewayEndpoint.normalizedOrigin(from: rhs) else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
    }

    private static func isValidDeviceCredential(_ credential: String, deviceID: String) -> Bool {
        let parts = credential.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "hfd1", parts[1] == Substring(deviceID),
              deviceID.count == 32,
              deviceID.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }), (32...128).contains(parts[2].count) else { return false }
        return (deviceID + String(parts[2])).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar == "-" || scalar == "_"
        }
    }

    public func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        // P1-6: same origin boundary on endpoint edits.
        let normalizedEdits: GatewayEdit
        if let endpoint = edits.endpoint {
            normalizedEdits = GatewayEdit(
                displayName: edits.displayName,
                endpoint: try GatewayEndpoint.normalizedOrigin(from: endpoint),
                authConfiguration: edits.authConfiguration
            )
        } else {
            normalizedEdits = edits
        }
        registry.update(id) { gateway in
            let updated = normalizedEdits.applied(to: gateway)
            gateway = updated
        }
        guard let updated = registry.gateway(for: id) else {
            throw GatewayRegistryError.notFound(id)
        }
        // P0-4: edits write through so a rename/endpoint change survives
        // relaunch. No rollback path needed — the in-memory edit already
        // succeeded; a store failure surfaces to the UI.
        try await persist(updated)
        return updated
    }

    public func removeGateway(_ id: GatewayID) async throws {
        guard let gateway = registry.gateway(for: id) else {
            throw GatewayRegistryError.notFound(id)
        }
        // #210: removal is a local operation. The durable record is the
        // commit marker — once it is gone the gateway is removed, whatever
        // the gateway's reachability or the secure stores report. Only a
        // failure to delete that local record keeps the entry (it would
        // otherwise resurrect on relaunch).
        if let recordStore {
            do {
                try await recordStore.deleteGatewayRecord(id: id)
            } catch {
                throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        registry.remove(id)

        // Secure material is retired best-effort after the commit. Enrollment
        // cleanup runs first: it snapshots what the (detached, best-effort)
        // device self-revoke needs before the credential and pin are deleted.
        // A failure here is logged, never surfaced as a removal failure.
        if let enrollmentCleanup {
            do { try await enrollmentCleanup.removeEnrollmentMaterial(for: gateway) }
            catch { Self.log.error("removal enrollment cleanup failed: \(Redaction.safeErrorDescription(error), privacy: .public)") }
        }
        do { try await credentials.deleteCredential(for: id) }
        catch { Self.log.error("removal credential cleanup failed: \(Redaction.safeErrorDescription(error), privacy: .public)") }
        if let pinStore {
            do { try await pinStore.deletePin(for: id) }
            catch { Self.log.error("removal pin cleanup failed: \(Redaction.safeErrorDescription(error), privacy: .public)") }
        }
    }

    private static let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "gateway-registry")

    public func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        do {
            try await credentials.saveCredential(credential, for: id)
        } catch {
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
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
        // P0-4: write the auth flag through to the durable record.
        if let updated = registry.gateway(for: id) {
            try await persist(updated)
        }
    }

    public func clearCredential(for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        // P2-4: a failed delete must surface — do NOT mark the gateway
        // un-configured while the secret may still exist.
        do {
            try await credentials.deleteCredential(for: id)
        } catch {
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
        }
        registry.update(id) { gateway in
            gateway.authConfigured = false
            gateway.authConfiguration = .none
        }
        // P0-4: write the cleared auth flag through to the durable record.
        if let updated = registry.gateway(for: id) {
            try await persist(updated)
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

    // MARK: P0-4 — durable record persistence + launch restore

    /// LEGACY MIGRATION TARGET (F2-era; Issue #2 review re-scope): the
    /// default endpoint legacy rows converge onto, supplied as DATA, never
    /// compiled Swift topology. Resolution order:
    /// 1. `HERMES_FLEET_DEFAULT_ENDPOINT` launch environment (explicit
    ///    legacy-migration lane; DEBUG builds only);
    /// 2. the `FleetDefaultEndpoint` key in the app's Info.plist — a PUBLIC
    ///    hostname only (not private topology, not an ATS exception).
    /// Nil/blank at both layers means "no migration target configured".
    ///
    /// IMPORTANT: resolving a target alone does NOT enable migration.
    /// Migration additionally requires `legacyEndpointMigrationEnabled`
    /// (below) — an explicit, OFF-by-default opt-in. A default endpoint
    /// merely being configured must never rewrite a user's persisted private
    /// gateway (Hermes Fleet explicitly supports user-owned LAN/tailnet
    /// gateways).
    nonisolated static var endpointMigrationDefault: String? {
        #if DEBUG
        // Launch-env override is DEBUG-only: a Release process must not be
        // redirectable to another endpoint via its launch environment.
        let env = ProcessInfo.processInfo.environment["HERMES_FLEET_DEFAULT_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        #endif
        let plist = (Bundle.main.object(forInfoDictionaryKey: "FleetDefaultEndpoint")
            as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plist.isEmpty ? nil : plist
    }

    /// LEGACY MIGRATION OPT-IN (Issue #2 review): OFF by default. When
    /// false (the public/default runtime state), `restorePersistedGateways()`
    /// NEVER rewrites persisted rows, no matter what endpoints they use —
    /// user-owned private/LAN/tailnet gateways survive verbatim. When
    /// explicitly enabled (the one-time legacy Fleet convergence lane), rows
    /// whose hosts classify as legacy private shapes are re-pointed onto
    /// `endpointMigrationDefault` via `EndpointMigration`.
    nonisolated static var legacyEndpointMigrationEnabled: Bool {
        #if DEBUG
        // DEBUG-only: the opt-in re-points persisted gateway rows, so it is
        // never reachable from a Release launch environment.
        ProcessInfo.processInfo.environment["HERMES_FLEET_LEGACY_MIGRATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "1"
        #else
        false
        #endif
    }

    /// Rebuild the in-memory registry from the durable record store.
    /// Idempotent: records whose ID is already registered are skipped, so a
    /// re-run (or an overlap with seeding) never duplicates entries. Restored
    /// gateways are marked `.disconnected` with auth flags re-derived from the
    /// credential store — the record itself is presentation data only.
    public func restorePersistedGateways() async throws -> [FleetGateway] {
        guard let recordStore else { return [] }
        // LEGACY endpoint convergence (F2-era; Issue #2 review re-scope):
        // runs ONLY when BOTH an explicit opt-in flag
        // (HERMES_FLEET_LEGACY_MIGRATION=1) and a migration target are
        // present — a deliberate one-time legacy-state migration lane. The
        // public/default runtime never migrates: user-owned private/LAN/
        // tailnet gateways survive restore verbatim. The target arrives as
        /// DATA from configuration, never compiled topology. Idempotent; a
        // store failure here must NOT brick launch (same tolerance as the
        // restore itself).
        if Self.legacyEndpointMigrationEnabled,
           let defaultEndpoint = Self.endpointMigrationDefault {
            _ = try? await GatewayEndpointMigrationService(recordStore: recordStore)
                .migrateAll(defaultEndpoint: defaultEndpoint)
        }
        let records = try await recordStore.loadGatewayRecords()
        var restored: [FleetGateway] = []
        for record in records {
            let id = GatewayID(rawValue: record.id)
            guard registry.gateway(for: id) == nil else { continue }
            let hasCredential = (try? await credentials.loadCredential(for: id)) != nil
            let gateway = FleetGateway(
                id: id,
                displayName: record.displayName,
                endpoint: URL(string: record.endpoint),
                connectionState: .disconnected,
                authConfigured: hasCredential,
                authConfiguration: GatewayAuthConfiguration(
                    strategy: record.authConfiguration.strategy,
                    credentialStored: hasCredential
                )
            )
            registry.register(gateway)
            restored.append(gateway)
        }
        return restored
    }

    /// Write one gateway's non-secret record through to the durable store.
    /// No-op when no record store is wired (scripted fleet / tests).
    private func persist(_ gateway: FleetGateway) async throws {
        guard let recordStore else { return }
        try await recordStore.saveGatewayRecord(StoredGatewayRecord(
            id: gateway.id.rawValue,
            displayName: gateway.displayName,
            endpoint: gateway.endpoint?.absoluteString ?? "",
            authConfiguration: gateway.authConfiguration,
            authConfigured: gateway.authConfigured
        ))
    }
}
