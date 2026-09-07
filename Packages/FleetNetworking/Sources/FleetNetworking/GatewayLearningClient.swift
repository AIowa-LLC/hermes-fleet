import Foundation
import os
import FleetCore

/// R9-T7 — concrete `GatewayLearningProviding` over the conversation
/// transport: the read-only learning star map (`learning.frames` +
/// `learning.detail`).
///
/// Wire ground truth (hermes-agent 0.21.0):
/// - `learning.frames` — tui_gateway/methods_tools.py:1840-1862. Params
///   `{cols, rows, frames}` (int-coerced; cols floored at 20, rows at 10,
///   frames clamped 2…240 — learning_graph_render.py:627). The result is
///   `render_frames` (learning_graph_render.py:626-657): a pre-rendered
///   TUI grid (O(frames) dead weight on a phone — ~69 KB at the 48-frame
///   default, ~10 KB at the 2-frame floor, measured live) PLUS structured
///   metadata the app DOES render: `buckets` (date slices with per-node
///   id/glyph/label/fullLabel/meta/body/style — `_bucket_rows` :345-361),
///   `legend`, `categories`, `summary` (`build_summary` :586-606),
///   `axis {start,end}` (:566-570), `count`.
/// - There is NO `learning.graph` WS method (exhaustive `@method` scan of
///   the registry); the structured nodes+edges payload is desktop-REST
///   (`GET /api/learning/graph`, web_server.py:4412). This client rides
///   the app's WS transport only.
/// - `learning.detail {id}` — methods_tools.py:1864-1872 → `node_detail`
///   (learning_mutations.py:86-118): `{ok, kind, id, label, content}`;
///   failure is `{ok: false, message}` (mapped to `.nodeNotFound`).
/// - Profile scoping: forwarded like cron/skills (`profile` param); the
///   0.21.0 handler signature reads `cols/rows/frames` only and IGNORES
///   `profile` (methods_tools.py:1846-1848) — the scope is harmless on
///   gateways that don't honor it and correct on ones that grow it.
public struct GatewayLearningClient: GatewayLearningProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "gateway-learning")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - learning.frames

    public func learningGraph(profile: String?) async throws -> LearningGraph {
        var params: [String: JSONValue] = [
            "cols": .number(60),
            "rows": .number(20),
            // Server floor (clamped ≥2): the buckets carry the data, the
            // pre-rendered grid runs are dead weight we never paint.
            "frames": .number(2),
        ]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "learning.frames", params: .object(params))
        return try Self.decodeGraph(result)
    }

    // MARK: - learning.detail

    public func nodeDetail(id: String) async throws -> LearningNodeDetail {
        let result = try await request(
            method: "learning.detail",
            params: .object(["id": .string(id)]))
        guard let o = result.objectValue else {
            throw GatewayLearningError.malformedResponse("learning.detail result was not an object")
        }
        // node_detail failure shape: {ok: false, message}.
        if o["ok"]?.boolValue == false {
            throw GatewayLearningError.nodeNotFound(
                o["message"]?.stringValue ?? "node not found")
        }
        guard let kind = o["kind"]?.stringValue,
              let nodeID = o["id"]?.stringValue else {
            throw GatewayLearningError.malformedResponse("learning.detail result missing kind/id")
        }
        return LearningNodeDetail(
            id: nodeID,
            kind: kind,
            label: o["label"]?.stringValue ?? nodeID,
            content: o["content"]?.stringValue ?? "")
    }

    // MARK: - learning.edit / learning.delete (R10-T5)

    /// `learning.edit {id, content}` → `edit_node`
    /// (learning_mutations.py:136-157): success `{ok: true, message}`,
    /// refusal `{ok: false, message}` → `.mutationFailed` (the message
    /// names the remedy and must reach the user verbatim).
    public func editNode(id: String, content: String) async throws -> String {
        let result = try await request(
            method: "learning.edit",
            params: .object(["id": .string(id), "content": .string(content)]))
        return try Self.decodeMutation(result, method: "learning.edit")
    }

    /// `learning.delete {id}` → `delete_node`
    /// (learning_mutations.py:108-131): skills are ARCHIVED (the success
    /// message carries the `hermes curator restore` recipe), memories are
    /// removed. Refusal `{ok: false, message}` → `.mutationFailed`.
    public func deleteNode(id: String) async throws -> String {
        let result = try await request(
            method: "learning.delete",
            params: .object(["id": .string(id)]))
        return try Self.decodeMutation(result, method: "learning.delete")
    }

    /// Shared `{ok, message}` envelope for the learning mutations.
    static func decodeMutation(_ result: JSONValue, method: String) throws -> String {
        guard let o = result.objectValue else {
            throw GatewayLearningError.malformedResponse("\(method) result was not an object")
        }
        if o["ok"]?.boolValue == false {
            throw GatewayLearningError.mutationFailed(
                o["message"]?.stringValue ?? "\(method) refused")
        }
        guard let message = o["message"]?.stringValue, !message.isEmpty else {
            throw GatewayLearningError.malformedResponse("\(method) result missing 'message'")
        }
        return message
    }

    // MARK: - decode

    /// `render_frames` result envelope → `LearningGraph` (grid `frames`
    /// ignored entirely — the app paints its own constellation).
    static func decodeGraph(_ result: JSONValue) throws -> LearningGraph {
        guard let bucketRows = result["buckets"]?.arrayValue else {
            throw GatewayLearningError.malformedResponse("learning.frames result missing 'buckets'")
        }
        var buckets: [LearningGraphBucket] = []
        for row in bucketRows {
            guard let o = row.objectValue else { continue }
            let index = o["index"]?.numberValue.map(Int.init) ?? buckets.count
            let nodes = (o["nodes"]?.arrayValue ?? []).compactMap(Self.decodeNode)
            buckets.append(LearningGraphBucket(
                index: index,
                label: o["label"]?.stringValue ?? "",
                date: o["date"]?.stringValue ?? "",
                category: o["category"]?.stringValue,
                nodes: nodes))
        }
        // Chronological order is the wire contract; sort defensively so a
        // scrambled envelope still lays out deterministically.
        buckets.sort { $0.index < $1.index }

        let summaryLines = result["summary"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let axis = result["axis"]?.objectValue
        let summary = LearningGraphSummary(
            lines: summaryLines,
            start: axis?["start"]?.stringValue ?? "oldest",
            end: axis?["end"]?.stringValue ?? "now",
            totalCount: result["count"]?.numberValue.map(Int.init) ?? buckets.count)
        return LearningGraph(buckets: buckets, summary: summary)
    }

    /// A `_bucket_nodes` row (learning_graph_render.py:344-357).
    static func decodeNode(_ value: JSONValue) -> LearningGraphNode? {
        guard let o = value.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        // Style key is the kind discriminator: "memory" (◆ diamond) vs
        // "skill" (● circle); fall back to the id prefix when absent.
        let isMemory: Bool
        if let style = o["style"]?.stringValue {
            isMemory = style == "memory"
        } else {
            isMemory = id.hasPrefix("memory:")
        }
        let full = o["fullLabel"]?.stringValue ?? o["label"]?.stringValue ?? id
        return LearningGraphNode(
            id: id,
            label: o["label"]?.stringValue ?? full,
            fullLabel: full,
            isMemory: isMemory,
            meta: o["meta"]?.stringValue ?? "",
            body: o["body"]?.stringValue ?? "")
    }

    // MARK: - transport

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        // Idempotent connect (P0-7) — the pane's transport starts cold; the
        // first learning RPC opens it.
        if !isTransportReady {
            try await transport.connect()
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    static func mapError(_ error: JSONRPCError) -> GatewayLearningError {
        switch error.code {
        default:
            return .rpcFailed("\(error.message) (\(error.code))")
        }
    }

    static func mapTransportError(_ error: TransportError) -> GatewayLearningError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(String(describing: error))
        }
    }
}
