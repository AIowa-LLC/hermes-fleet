import Foundation
import os

/// In-memory `TLSPinStoring` — test double / preview store (T3).
///
/// Mirrors the Keychain pin store's contract exactly (save/load/delete,
/// missing item is nil / no-op, errors carry no secrets) but holds values in
/// a plain dictionary for unit tests and SwiftUI previews. NEVER used in
/// production.
public final class InMemoryPinStore: TLSPinStoring, SynchronousPinStoring,
    TLSFirstUseApprovalStoring, SynchronousTLSFirstUseApprovalStoring,
    @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: SPKIFingerprint]>(initialState: [:])
    private let approvalLock = OSAllocatedUnfairLock<[String: SPKIFingerprint?]>(initialState: [:])

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

    public func syncSavePinIfAbsent(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws -> Bool {
        lock.withLock {
            guard $0[gatewayID.rawValue] == nil else { return false }
            $0[gatewayID.rawValue] = pin
            return true
        }
    }

    public func syncDeletePin(for gatewayID: GatewayID) throws {
        _ = lock.withLock { $0.removeValue(forKey: gatewayID.rawValue) }
        try syncSetFirstUseApproved(false, for: gatewayID)
    }

    // MARK: TLSFirstUseApprovalStoring

    public func approveFirstUse(for gatewayID: GatewayID) async throws {
        try syncSetFirstUseApproved(true, for: gatewayID)
    }

    public func approveFirstUse(for gatewayID: GatewayID, boundTo fingerprint: SPKIFingerprint) async throws {
        try syncSetFirstUseApproval(boundTo: fingerprint, for: gatewayID)
    }

    public func isFirstUseApproved(for gatewayID: GatewayID) async throws -> Bool {
        try syncIsFirstUseApproved(for: gatewayID)
    }

    public func resetFirstUseApproval(for gatewayID: GatewayID) async throws {
        try syncSetFirstUseApproved(false, for: gatewayID)
    }

    // MARK: SynchronousTLSFirstUseApprovalStoring

    public func syncIsFirstUseApproved(for gatewayID: GatewayID) throws -> Bool {
        approvalLock.withLock { $0.keys.contains(gatewayID.rawValue) }
    }

    public func syncSetFirstUseApproved(_ approved: Bool, for gatewayID: GatewayID) throws {
        if approved {
            try syncSetFirstUseApproval(boundTo: nil, for: gatewayID)
        } else {
            approvalLock.withLock { _ = $0.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    public func syncSetFirstUseApproval(boundTo fingerprint: SPKIFingerprint?, for gatewayID: GatewayID) throws {
        approvalLock.withLock { $0[gatewayID.rawValue] = .some(fingerprint) }
    }

    public func syncConsumeFirstUseApproval(matching presented: SPKIFingerprint, for gatewayID: GatewayID) throws -> Bool {
        approvalLock.withLock {
            guard let entry = $0[gatewayID.rawValue] else { return false }
            if let bound = entry, bound != presented { return false }
            $0.removeValue(forKey: gatewayID.rawValue)
            return true
        }
    }
}
