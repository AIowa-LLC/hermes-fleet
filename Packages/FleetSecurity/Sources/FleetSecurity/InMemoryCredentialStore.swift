import Foundation
import os
import FleetCore

/// In-memory `CredentialStoring` — test double / preview store.
///
/// Mirrors the Keychain store's contract exactly (save/load/delete, missing
/// item is nil / no-op, errors carry no secrets) and uses the SAME
/// `CredentialEncoding` as the Keychain store, so the username/password
/// composite round-trips identically in tests and previews. Holds the
/// encoded bytes in a plain dictionary for unit tests and SwiftUI previews.
/// NEVER used in production.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    public init() {}

    public func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
        lock.withLock { storage in
            storage[gatewayID.rawValue] = CredentialEncoding.encode(credential)
        }
    }

    public func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
        lock.withLock { storage in
            guard let data = storage[gatewayID.rawValue] else { return nil }
            return try? CredentialEncoding.decode(data)
        }
    }

    public func deleteCredential(for gatewayID: GatewayID) async throws {
        _ = lock.withLock { storage in
            storage.removeValue(forKey: gatewayID.rawValue)
        }
    }
}
