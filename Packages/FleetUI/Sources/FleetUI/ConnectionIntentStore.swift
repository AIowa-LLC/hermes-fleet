import Foundation
import os
import FleetCore

/// The user's desired connection state, kept separate from live transport
/// state. Only gateway IDs are persisted; credentials and authenticated
/// sessions remain in their existing secure/ephemeral stores.
@MainActor
public final class ConnectionIntentStore: Sendable {
    public static let defaultsKey = "fleet.connection.intent.gatewayIDs.v1"

    private let defaults: UserDefaults?
    private let lock = OSAllocatedUnfairLock(initialState: Set<GatewayID>())

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let defaults, let raw = defaults.stringArray(forKey: Self.defaultsKey) {
            lock.withLock { $0.formUnion(raw.map(GatewayID.init(rawValue:))) }
        }
    }

    public var intendedGatewayIDs: Set<GatewayID> {
        get { lock.withLock { $0 } }
        set {
            lock.withLock { $0 = newValue }
            defaults?.set(newValue.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
        }
    }

    public func record(_ id: GatewayID) {
        var ids = intendedGatewayIDs
        ids.insert(id)
        intendedGatewayIDs = ids
    }

    public func clear(_ id: GatewayID) {
        var ids = intendedGatewayIDs
        ids.remove(id)
        intendedGatewayIDs = ids
    }

    public func isIntended(_ id: GatewayID) -> Bool {
        intendedGatewayIDs.contains(id)
    }

    public func prune(to known: Set<GatewayID>) {
        intendedGatewayIDs = intendedGatewayIDs.intersection(known)
    }

    public func removeAll() {
        intendedGatewayIDs = []
    }
}
