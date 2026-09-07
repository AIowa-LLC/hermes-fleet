import Foundation

/// The non-secret cache seam (synthesis §12: SwiftData caches non-secret
/// session/event history + seq watermarks + last replay_epoch; relaunch-resume;
/// stale epoch → reset; "structurally no credentials in cache").
///
/// Lives in FleetCore so the replay/service layer and the app composition root
/// depend on this protocol — never on the concrete SwiftData implementation in
/// FleetPersistence (mirrors the M7 `CredentialStoring` seam pattern). The
/// concrete store is `SwiftDataCacheStore` (FleetPersistence); tests use an
/// in-memory SwiftData container.
///
/// Structural no-secret invariant: this protocol has NO token/credential
/// parameter and its models hold no secret field — tokens/tickets live only in
/// Keychain (`TokenStoring`), never here.
public protocol CacheStoring: Sendable {
    // MARK: Session history (non-secret transcript)

    /// Store (replace) the full transcript for a (gateway, session) pair.
    func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws
    /// Load the stored transcript for a (gateway, session) pair, or `nil`.
    func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory?
    /// Delete the stored transcript for a (gateway, session) pair.
    func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws

    // MARK: Seq watermarks (per (gateway, session))

    /// Store (upsert) the highest observed seq watermark for a session.
    func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws
    /// Load all stored watermarks.
    func loadWatermarks() async throws -> [SessionEventWatermark]
    /// Remove all stored watermarks (used on replay_epoch change — the stale
    /// seq assumptions are discarded per spec §9.6 / synthesis §10).
    func clearWatermarks() async throws

    // MARK: Replay epoch (per gateway)

    /// Store the last adopted replay_epoch for a gateway (`nil` = none).
    func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws
    /// Load the last adopted replay_epoch for a gateway (`nil` when none).
    func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String?

    // MARK: Reset (relaunch-resume; stale epoch → reset)

    /// Discard the cached state for a gateway — history + watermarks + epoch —
    /// so the client rehydrates from authoritative server state. Fail-closed
    /// on a stale replay_epoch (spec §9.6 / §31 Reconnect).
    func resetForReplayEpochChange(gatewayID: GatewayID) async throws
}

/// Errors a `CacheStoring` implementation surfaces. None carry secret
/// material (spec §29: no secrets in error text).
public enum CacheStoreError: Error, Sendable, Equatable, LocalizedError {
    /// The underlying store call failed.
    case storeUnavailable(String)
    /// Stored data could not be decoded into a domain value.
    case malformedData(String)
    /// The requested operation is not supported by this store.
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let detail): return "cache store unavailable: \(detail)"
        case .malformedData(let detail): return "cache data malformed: \(detail)"
        case .unsupported: return "cache operation not supported"
        }
    }
}
