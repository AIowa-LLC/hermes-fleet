import Foundation
import os
import FleetCore

/// In-memory `CredentialStoring` — test double / preview store.
///
/// Mirrors the Keychain store's contract exactly (save/load/delete, missing
/// item is nil / no-op, errors carry no secrets) but holds values in a plain
/// dictionary for unit tests and SwiftUI previews. NEVER used in production.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    public init() {}

    public func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
        lock.withLock { storage in
            storage[gatewayID.rawValue] = credential.rawValue
        }
    }

    public func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
        lock.withLock { storage in
            storage[gatewayID.rawValue].map(GatewayCredential.init(rawValue:))
        }
    }

    public func deleteCredential(for gatewayID: GatewayID) async throws {
        lock.withLock { storage in
            storage.removeValue(forKey: gatewayID.rawValue)
        }
    }
}
