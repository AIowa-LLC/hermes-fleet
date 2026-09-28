import Foundation
import FleetCore

/// Reads the companion Hermes plugin's cross-process snapshot. The legacy RPC
/// remains a fallback for installations without the plugin, with explicit scope.
/// Observing a Desktop process does not grant its session's control authority.
public struct DashboardLiveOpsClient: LiveOpsProviding, LiveOpsSubagentControlling {
    private let gatewayID: GatewayID
    private let baseURL: URL
    private let legacy: GatewayLiveOpsClient
    private let credential: @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential
    private let urlSession: URLSession

    public init(gatewayID: GatewayID, baseURL: URL, legacy: GatewayLiveOpsClient,
                httpCredential: @escaping @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential,
                urlSession: URLSession = .shared) {
        self.gatewayID = gatewayID
        self.baseURL = baseURL
        self.legacy = legacy
        self.credential = httpCredential
        self.urlSession = urlSession
    }

    public func snapshot(gateway: GatewayID) async -> LiveOpsGatewaySnapshot {
        let now = Date()
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/plugins/fleet-liveops/snapshot"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 4
            switch try await credential() {
            case .none: break
            case .sessionTokenHeader(let token): request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
            case .cookie(let cookie): request.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
            }
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SnapshotError.invalid }
            if http.statusCode == 404 {
                let fallback = await legacy.snapshot()
                return LiveOpsGatewaySnapshot(
                    gatewayID: gatewayID, coverage: fallback.coverage, operations: fallback.operations,
                    observedAt: fallback.observedAt,
                    observationNote: "Only this gateway process is visible. Desktop runs in other profiles require the Hermes Fleet live reporting plugin.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return LiveOpsGatewaySnapshot(gatewayID: gatewayID, coverage: .authFailed, operations: [], observedAt: now)
            }
            guard http.statusCode == 200, data.count <= AuthREST.maxResponseBytes else { throw SnapshotError.invalid }
            let payload = try JSONDecoder().decode(JSONValue.self, from: data)
            if (payload["stale_publishers"]?.intValue ?? 0) > 0 {
                return LiveOpsGatewaySnapshot(
                    gatewayID: gatewayID, coverage: .failed(reason: "A Hermes live reporter stopped responding"),
                    operations: [], observedAt: now)
            }
            guard payload["schema"]?.intValue == 1,
                  let publishers = payload["publishers"]?.intValue, publishers > 0,
                  let rows = payload["sessions"]?.arrayValue else { throw SnapshotError.invalid }
            var operations: [LiveOperation] = []
            for row in rows.prefix(GatewayLiveOpsClient.maxSessionRows) {
                guard let op = GatewayLiveOpsClient.decodeOperation(gatewayID: gatewayID, row: row),
                      op.id.runtimeSessionID.hasPrefix("fleet:"),
                      let children = row["subagents"]?.arrayValue else { throw SnapshotError.invalid }
                operations.append(LiveOperation(
                    id: op.id, sessionKey: op.sessionKey, title: op.title, preview: op.preview,
                    model: op.model, startedAt: op.startedAt, lastActive: op.lastActive,
                    messageCount: op.messageCount, status: op.status,
                    subagents: children.prefix(GatewayLiveOpsClient.maxSubagentRows).compactMap(GatewayLiveOpsClient.decodeSubagent),
                    observationOnly: true))
            }
            return LiveOpsGatewaySnapshot(
                gatewayID: gatewayID, coverage: .reporting, operations: operations, observedAt: now,
                observationNote: "Live reporting from \(publishers) Hermes backend\(publishers == 1 ? "" : "s"). Only backends with the reporting plugin enabled are visible.")
        } catch {
            return LiveOpsGatewaySnapshot(
                gatewayID: gatewayID, coverage: .failed(reason: "Live reporting unavailable"), operations: [], observedAt: now)
        }
    }

    private enum SnapshotError: Error { case invalid }

    private func requireLocal(_ sessionID: String) throws {
        guard !sessionID.hasPrefix("fleet:") else { throw LiveOpsControlError.notAttached }
    }

    public func listSubagents(sessionID: String) async throws -> [LiveOpsSubagent] {
        try requireLocal(sessionID)
        return try await legacy.listSubagents(sessionID: sessionID)
    }
    public func tail(subagentID: String, sessionID: String) async throws -> LiveOpsSubagentTail {
        try requireLocal(sessionID)
        return try await legacy.tail(subagentID: subagentID, sessionID: sessionID)
    }
    public func steer(subagentID: String, sessionID: String, text: String) async throws -> LiveOpsSteerResult {
        try requireLocal(sessionID)
        return try await legacy.steer(subagentID: subagentID, sessionID: sessionID, text: text)
    }
    public func interrupt(subagentID: String, sessionID: String) async throws -> Bool {
        try requireLocal(sessionID)
        return try await legacy.interrupt(subagentID: subagentID, sessionID: sessionID)
    }
}
