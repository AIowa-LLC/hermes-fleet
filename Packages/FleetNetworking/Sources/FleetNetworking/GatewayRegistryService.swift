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
    /// P0-4: durable non-secret gateway-record store. Every durable mutation
    /// writes through immediately; `nil` (scripted fleet / tests) keeps the
    /// registry purely in-memory, exactly as before.
    private let recordStore: (any GatewayRecordStoring)?
    /// T3: per-gateway TLS pin store (TOFU SPKI pinning). `nil` keeps the
    /// registry pin-unaware (scripted fleet / legacy tests).
    private let pinStore: (any TLSPinStoring)?
    /// Durable "removal in progress" markers (nil keeps removal in-memory only).
    private let removalLedger: (any GatewayRemovalLedgering)?
    /// Gateways whose removal is in flight. Actor reentrancy lets other calls
    /// (a launch restore, a late credential save) run at every `await` inside
    /// a removal; this set is what keeps them from reviving or touching it.
    private var removing: Set<GatewayID> = []
    /// Gateways explicitly removed during this process. A stale record
    /// snapshot taken before the removal must never re-register one of them;
    /// only a deliberate `addGateway` lifts the fence.
    private var retired: Set<GatewayID> = []

    public init(
        registry: GatewayRegistry = GatewayRegistry(),
        credentials: any CredentialStoring,
        connectionFactory: @escaping GatewayConnectionFactory,
        recordStore: (any GatewayRecordStoring)? = nil,
        pinStore: (any TLSPinStoring)? = nil,
        removalLedger: (any GatewayRemovalLedgering)? = nil
    ) {
        self.removalLedger = removalLedger
        self.registry = registry
        self.credentials = credentials
        self.connectionFactory = connectionFactory
        self.recordStore = recordStore
        self.pinStore = pinStore
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
        guard registry.gateway(for: id) == nil, !removing.contains(id) else {
            throw GatewayRegistryError.duplicate(id)
        }
        // A deliberate Add is the only way a removed gateway returns: lift the
        // removal marker FIRST so a crash between the marker and the record
        // write cannot make the next launch delete the freshly added record.
        if let removalLedger {
            do {
                try await removalLedger.clear(id)
            } catch {
                throw GatewayRegistryError.removalStateStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        // Re-check: another call may have registered this ID while we awaited.
        guard registry.gateway(for: id) == nil, !removing.contains(id) else {
            throw GatewayRegistryError.duplicate(id)
        }
        let gateway = FleetGateway(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            authConfiguration: registration.authConfiguration
        )
        retired.remove(id)
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

    public func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        guard registry.gateway(for: id) != nil, !removing.contains(id) else {
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

    /// Remove a gateway for good.
    ///
    /// The removal is all-or-nothing from the user's point of view:
    /// 1. A durable removal marker is written first; if that fails nothing is
    ///    touched and the error is reported.
    /// 2. The reversible step (the saved record) goes before the irreversible
    ///    ones (the Keychain credential, the TLS pin). A failure at any later
    ///    step restores everything already deleted, clears the marker, and
    ///    reports the failure; the gateway stays listed and intact.
    /// 3. Only when every store agrees is the gateway dropped from memory and
    ///    fenced against stale restores.
    ///
    /// A process kill after step 1 leaves the marker behind, so the next
    /// launch finishes the removal instead of reviving the gateway.
    public func removeGateway(_ id: GatewayID) async throws {
        guard let gateway = registry.gateway(for: id), !removing.contains(id) else {
            throw GatewayRegistryError.notFound(id)
        }
        removing.insert(id)
        defer { removing.remove(id) }

        if let removalLedger {
            do {
                try await removalLedger.markRemoving(id)
            } catch {
                throw GatewayRegistryError.removalStateStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        // Held only to undo a later failure; never logged or persisted here.
        let savedCredential = try? await credentials.loadCredential(for: id)

        var recordDeleted = false
        var credentialDeleted = false
        func abort(_ failure: GatewayRegistryError) async -> GatewayRegistryError {
            var restored = true
            if recordDeleted {
                do { try await persist(gateway) } catch { restored = false }
            }
            if credentialDeleted, let savedCredential {
                do { try await credentials.saveCredential(savedCredential, for: id) } catch { restored = false }
            }
            if restored {
                try? await removalLedger?.clear(id)
                return failure
            }
            // The rollback itself failed: keep the marker so the next launch
            // completes the removal rather than leaving a half-deleted
            // gateway, and say so.
            return GatewayRegistryError.removalStateStoreFailed(
                "removal could not be undone; it will finish when Fleet restarts")
        }

        if let recordStore {
            do {
                try await recordStore.deleteGatewayRecord(id: id)
                recordDeleted = true
            } catch {
                throw await abort(.recordStoreFailed(Redaction.safeErrorDescription(error)))
            }
        }
        // P1-8: credential cleanup failure must surface — never swallowed.
        do {
            try await credentials.deleteCredential(for: id)
            credentialDeleted = true
        } catch {
            throw await abort(.credentialStoreFailed(Redaction.safeErrorDescription(error)))
        }
        // T3: retire the TLS pin with the credential — a removed gateway must
        // leave no orphaned trust material.
        if let pinStore {
            do {
                try await pinStore.deletePin(for: id)
            } catch {
                throw await abort(.pinStoreFailed(Redaction.safeErrorDescription(error)))
            }
        }
        registry.remove(id)
        retired.insert(id)
        // Best effort: a marker that outlives a completed removal is harmless
        // (restore skips it and re-runs idempotent cleanup).
        try? await removalLedger?.clear(id)
    }

    public func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil, !removing.contains(id) else {
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
        // A removal that was interrupted (force-quit, crash) is finished here,
        // before anything is restored; an unreadable marker file fails the
        // restore (the caller retries) instead of reviving a removed gateway.
        let interrupted = try await finishInterruptedRemovals()
        let records = try await recordStore.loadGatewayRecords()
        var restored: [FleetGateway] = []
        for record in records {
            let id = GatewayID(rawValue: record.id)
            guard isRestorable(id, interrupted: interrupted) else { continue }
            // A credential READ FAILURE (Keychain unavailable, e.g. device
            // locked on a background launch) is not "no credential": keep the
            // durable record's flag rather than relabelling a configured
            // gateway as unconfigured. Only a definitive not-found is false.
            let hasCredential: Bool
            do {
                hasCredential = try await credentials.loadCredential(for: id) != nil
            } catch {
                hasCredential = record.authConfigured
            }
            // The credential read suspended this actor: the record snapshot
            // above may now describe a gateway the user has since removed.
            guard isRestorable(id, interrupted: interrupted) else { continue }
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

    /// Whether a saved record may be (re)registered right now. Re-evaluated
    /// after every suspension point of a restore.
    private func isRestorable(_ id: GatewayID, interrupted: Set<GatewayID>) -> Bool {
        registry.gateway(for: id) == nil
            && !removing.contains(id)
            && !retired.contains(id)
            && !interrupted.contains(id)
    }

    /// Finish removals that a previous process started but did not complete:
    /// delete whatever the marker's gateway still has in each store, then drop
    /// the marker. Idempotent and best effort per store; a store that still
    /// fails keeps its marker so the next launch tries again. Returns every
    /// marked ID so the caller never restores it meanwhile.
    private func finishInterruptedRemovals() async throws -> Set<GatewayID> {
        guard let removalLedger else { return [] }
        let marked = try await removalLedger.pendingRemovals()
        for id in marked where registry.gateway(for: id) == nil && !removing.contains(id) {
            retired.insert(id)
            var complete = true
            if let recordStore {
                do { try await recordStore.deleteGatewayRecord(id: id) } catch { complete = false }
            }
            do { try await credentials.deleteCredential(for: id) } catch { complete = false }
            if let pinStore {
                do { try await pinStore.deletePin(for: id) } catch { complete = false }
            }
            if complete { try? await removalLedger.clear(id) }
        }
        return marked
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
