import Foundation
import FleetCore

/// In-memory, per-gateway ownership of the username/password session cookie.
/// Tickets remain single-use; only the full password login is shared.
public actor GatewaySessionStore {
    private var sessions: [GatewayID: SessionCookie] = [:]
    private var inFlightLogins: [GatewayID: Task<SessionCookie, Error>] = [:]
    private var generations: [GatewayID: Int] = [:]
    private var inFlightGenerations: [GatewayID: Int] = [:]
    private let onSharedFlightWait: (@Sendable () -> Void)?

    public init() {
        onSharedFlightWait = nil
    }

    /// Package-test seam for proving that a caller took the shared-flight
    /// waiter path. It is intentionally not part of the public API.
    internal init(onSharedFlightWait: @escaping @Sendable () -> Void) {
        self.onSharedFlightWait = onSharedFlightWait
    }

    public func lease(
        gatewayID: GatewayID,
        login: @escaping @Sendable () async throws -> SessionCookie
    ) async throws -> SessionCookie {
        let generation = generations[gatewayID, default: 0]
        if let cookie = sessions[gatewayID] { return cookie }
        if let flight = inFlightLogins[gatewayID],
           inFlightGenerations[gatewayID] == generation {
            onSharedFlightWait?()
            do {
                let cookie = try await flight.value
                guard generations[gatewayID, default: 0] == generation else {
                    return try await lease(gatewayID: gatewayID, login: login)
                }
                return cookie
            } catch {
                // Match the task-creating caller: if invalidation advanced
                // the generation while the shared flight was pending, retry
                // against the current generation instead of leaking an
                // obsolete flight's cancellation to the waiter.
                guard generations[gatewayID, default: 0] != generation else { throw error }
                return try await lease(gatewayID: gatewayID, login: login)
            }
        }

        let task = Task<SessionCookie, Error> { try await login() }
        inFlightLogins[gatewayID] = task
        inFlightGenerations[gatewayID] = generation
        defer {
            if inFlightGenerations[gatewayID] == generation {
                inFlightLogins[gatewayID] = nil
                inFlightGenerations[gatewayID] = nil
            }
        }

        let cookie: SessionCookie
        do {
            cookie = try await task.value
        } catch {
            // Invalidation cancels best-effort. If the underlying request
            // honored cancellation, retry against the newer generation rather
            // than leaking cancellation from an obsolete lease to callers.
            guard generations[gatewayID, default: 0] != generation else { throw error }
            return try await lease(gatewayID: gatewayID, login: login)
        }
        // A credential/configuration change may have invalidated this login
        // while the network request was in flight. Never cache OR return the
        // old credential's cookie; retry against the current generation.
        guard generations[gatewayID, default: 0] == generation else {
            return try await lease(gatewayID: gatewayID, login: login)
        }
        sessions[gatewayID] = cookie
        return cookie
    }

    /// Invalidate both the cached lease and any in-flight generation. The
    /// underlying request may finish, but its result cannot be cached.
    public func invalidate(gatewayID: GatewayID) {
        sessions[gatewayID] = nil
        generations[gatewayID, default: 0] += 1
        inFlightLogins[gatewayID]?.cancel()
        inFlightLogins[gatewayID] = nil
        inFlightGenerations[gatewayID] = nil
    }

    public func invalidateAll() {
        let ids = Set(sessions.keys).union(inFlightLogins.keys)
        for id in ids { invalidate(gatewayID: id) }
    }
}

extension GatewaySessionStore: CustomStringConvertible, CustomDebugStringConvertible {
    public nonisolated var description: String { "GatewaySessionStore(redacted)" }
    public nonisolated var debugDescription: String { description }
}

extension GatewaySessionStore: GatewayAuthenticator.GatewaySessionLeasing {}
