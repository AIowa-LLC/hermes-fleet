import Foundation
import os
import FleetCore

/// In-memory `OAuthTokenStoring` — test double / preview store.
/// NEVER used in production (synthesis §12: tokens live only in Keychain).
public final class InMemoryOAuthTokenStore: OAuthTokenStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: OAuthTokenPair]>(initialState: [:])

    public init() {}

    public func saveTokenPair(_ pair: OAuthTokenPair, for gatewayID: GatewayID) async throws {
        lock.withLock { storage in
            storage[gatewayID.rawValue] = pair
        }
    }

    public func loadTokenPair(for gatewayID: GatewayID) async throws -> OAuthTokenPair? {
        lock.withLock { storage in
            storage[gatewayID.rawValue]
        }
    }

    public func deleteTokenPair(for gatewayID: GatewayID) async throws {
        _ = lock.withLock { storage in
            storage.removeValue(forKey: gatewayID.rawValue)
        }
    }
}
