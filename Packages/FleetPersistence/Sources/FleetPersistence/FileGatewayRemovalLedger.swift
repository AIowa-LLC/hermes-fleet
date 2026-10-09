import Foundation
import FleetCore

/// File-backed `GatewayRemovalLedgering`: gateway identifiers only, written
/// atomically with the same protection as the other device-local stores
/// (`NSFileProtectionComplete`, backup-excluded). Holds no credential,
/// endpoint or display name.
///
/// Unreadable content is an ERROR, never "no markers": a corrupt or
/// still-locked ledger must fail the launch restore (which retries) rather
/// than silently reviving a gateway the user removed.
public actor FileGatewayRemovalLedger: GatewayRemovalLedgering {
    public static let fileName = "fleet-gateway-removals.json"

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func markRemoving(_ id: GatewayID) async throws {
        var ids = try read()
        ids.insert(id.rawValue)
        try write(ids)
    }

    public func pendingRemovals() async throws -> Set<GatewayID> {
        Set(try read().map(GatewayID.init(rawValue:)))
    }

    public func clear(_ id: GatewayID) async throws {
        var ids = try read()
        guard ids.remove(id.rawValue) != nil else { return }
        if ids.isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try write(ids)
        }
    }

    private func read() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return Set(try JSONDecoder().decode([String].self, from: data))
        } catch {
            // No payload: the error text must not carry paths or identifiers.
            throw GatewayRemovalLedgerError.unavailable
        }
    }

    private func write(_ ids: Set<String>) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ids.sorted())
            // `NSFileProtectionComplete` is an iOS data-protection class; on a
            // macOS host (package tests) it can fail while the machine is locked.
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: [.atomic])
            #endif
            try CacheStoreProtection.apply(to: url)
        } catch {
            throw GatewayRemovalLedgerError.unavailable
        }
    }
}
