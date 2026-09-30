import Foundation
import FleetCore

/// Shared by cache actors using one container. Removal fences delayed writes
/// before deleting rows; only a successful gateway registration opens it again.
/// The lock covers synchronous ModelContext operations so launch-cache writes
/// cannot interleave with purge. No fence survives process exit: old writers do
/// not survive it either, and no persisted schema change is needed.
public final class GatewayCacheWriteFence: @unchecked Sendable {
    private let lock = NSLock()
    private var removed: Set<GatewayID> = []

    public init() {}

    func write<T>(for id: GatewayID, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !removed.contains(id) else {
                throw CacheStoreError.storeUnavailable("Gateway was removed")
            }
            return try body()
        }
    }

    func purge(for id: GatewayID, _ body: () throws -> Void) throws {
        try lock.withLock {
            removed.insert(id)
            try body()
        }
    }

    func register(id: GatewayID, _ body: () throws -> Void) throws {
        try lock.withLock {
            try body()
            removed.remove(id)
        }
    }
}
