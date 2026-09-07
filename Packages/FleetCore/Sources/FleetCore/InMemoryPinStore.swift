import Foundation
import os

/// In-memory `TLSPinStoring` — test double / preview store (T3).
///
/// Mirrors the Keychain pin store's contract exactly (save/load/delete,
/// missing item is nil / no-op, errors carry no secrets) but holds values in
/// a plain dictionary for unit tests and SwiftUI previews. NEVER used in
/// production.
public final class InMemoryPinStore: TLSPinStoring, SynchronousPinStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: SPKIFingerprint]>(initialState: [:])

    public init() {}

    public func savePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) async throws {
        try syncSavePin(pin, for: gatewayID)
    }

    public func loadPin(for gatewayID: GatewayID) async throws -> SPKIFingerprint? {
        try syncLoadPin(for: gatewayID)
    }

    public func deletePin(for gatewayID: GatewayID) async throws {
        try syncDeletePin(for: gatewayID)
    }

    // MARK: SynchronousPinStoring

    public func syncSavePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws {
        lock.withLock { $0[gatewayID.rawValue] = pin }
    }

    public func syncLoadPin(for gatewayID: GatewayID) throws -> SPKIFingerprint? {
        lock.withLock { $0[gatewayID.rawValue] }
    }

    public func syncDeletePin(for gatewayID: GatewayID) throws {
        _ = lock.withLock { $0.removeValue(forKey: gatewayID.rawValue) }
    }
}
