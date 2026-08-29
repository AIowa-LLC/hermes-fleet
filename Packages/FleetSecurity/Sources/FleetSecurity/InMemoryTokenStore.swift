import Foundation
import os
import FleetCore

/// In-memory `TokenStoring` — test double / preview store.
///
/// Mirrors the Keychain token store's contract exactly (save/load/delete,
/// missing item is nil / no-op, errors carry no secrets) but holds values in
/// a plain dictionary for unit tests and SwiftUI previews. NEVER used in
/// production (synthesis §12: tokens live only in Keychain).
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    public init() {}

    public func saveToken(_ token: StoredToken, for gatewayID: GatewayID) async throws {
        lock.withLock { storage in
            storage[gatewayID.rawValue] = token.rawValue
        }
    }

    public func loadToken(for gatewayID: GatewayID) async throws -> StoredToken? {
        lock.withLock { storage in
            storage[gatewayID.rawValue].map(StoredToken.init(rawValue:))
        }
    }

    public func deleteToken(for gatewayID: GatewayID) async throws {
        _ = lock.withLock { storage in
            storage.removeValue(forKey: gatewayID.rawValue)
        }
    }
}
