import Foundation

/// R9-T7 — read-only Memory Graph (learning star map) models + seam.
///
/// WIRE GROUND TRUTH (hermes-agent 0.21.0, installed source):
/// - There is NO `learning.graph` method on the WS registry. The learning
///   surface over WS is `learning.frames` (tui_gateway/methods_tools.py:
///   1840-1862), `learning.detail` (:1864-1872), `learning.edit` (:1875),
///   `learning.delete` (:1878). The structured nodes+edges payload
///   (`build_learning_graph`, agent/learning_graph.py:254) is served to the
///   DESKTOP panel via REST `GET /api/learning/graph`
///   (hermes_cli/web_server.py:4412-4420) — not over this app's WS
///   transport.
/// - `learning.frames {cols, rows, frames}` returns
///   `render_frames(payload, cols, rows, frames)`
///   (agent/learning_graph_render.py:626-657): a pre-rendered TUI grid we
///   do NOT paint, PLUS fully structured metadata the phone CAN render:
///   `buckets` (one row per date slice; nodes with id/glyph/label/
///   fullLabel/meta/body/style, learning_graph_render.py:332-361),
///   `legend`, `categories`, `summary` (build_summary :586-606),
///   `axis {start, end}` (:566-570), `count`.
/// - `learning.detail {id}` → `node_detail` (agent/learning_mutations.py:
///   86-118): `{ok, kind: "skill"|"memory", id, label, content}` where
///   content is the full SKILL.md or the raw memory chunk; failures come
///   back as `{ok: false, message}`.
/// - PAYLOAD SIZE (measured live on this Mac's profile, 2026-09-04, via
///   the exact handler code path): 14 nodes / 13 edges / 10 memories;
///   raw graph JSON 10,011 B; `learning.frames` frames=2 JSON 10,027 B
///   (frames=48 balloons to ~69 KB of grid runs we never paint). The
///   client therefore asks for `frames: 2` (server floor) — the buckets
///   carry the data, the app renders its own constellation.
/// - FILTER HONESTY: the plan's All/Used/Learned filter is NOT derivable
///   from the WS payload — bucket node rows carry no useCount/createdBy
///   (learning_graph_render.py:344-357), and `build_learning_graph`
///   already excludes base/unlearned skills (learning_graph.py:266-270:
///   only agent-created or used skills survive). The honest filter set is
///   All / Skills / Memories.
public struct LearningGraphNode: Identifiable, Hashable, Codable, Sendable {
    /// Stable wire id — skill name, or `memory:<source>:<i>`.
    public let id: String
    /// Truncated display label (server-side, ≤26 chars).
    public let label: String
    /// Untruncated label.
    public let fullLabel: String
    /// True for memory nodes (diamond ◆), false for skills (circle ●).
    public let isMemory: Bool
    /// Server-composed metadata line ("category · date · xN").
    public let meta: String
    /// Memory chunk body (empty for skills on this surface).
    public let body: String

    public init(
        id: String,
        label: String,
        fullLabel: String,
        isMemory: Bool,
        meta: String = "",
        body: String = ""
    ) {
        self.id = id
        self.label = label
        self.fullLabel = fullLabel
        self.isMemory = isMemory
        self.meta = meta
        self.body = body
    }
}

/// One date slice of the journey timeline (`buckets[i]`,
/// learning_graph_render.py:345-361 `_bucket_rows`).
public struct LearningGraphBucket: Identifiable, Hashable, Codable, Sendable {
    /// Wire bucket index (chronological, oldest first).
    public let index: Int
    /// Short slice label ("4 Sep" / "Sep 2026").
    public let label: String
    /// Full formatted date of the slice.
    public let date: String
    /// Dominant skill category of the slice (nil when memory-only).
    public let category: String?
    /// Nodes in this slice, chronological within the bucket.
    public let nodes: [LearningGraphNode]

    public var id: Int { index }

    public init(index: Int, label: String, date: String, category: String?, nodes: [LearningGraphNode]) {
        self.index = index
        self.label = label
        self.date = date
        self.category = category
        self.nodes = nodes
    }
}

/// Legend + summary + axis + count as `learning.frames` reports them.
public struct LearningGraphSummary: Hashable, Codable, Sendable {
    /// "14 learned skills · 10 memories · …" style lines (non-secret).
    public let lines: [String]
    /// Timeline axis: "oldest … now" (untimed) or formatted dates.
    public let start: String
    /// Newest axis label ("now" when untimed).
    public let end: String
    /// Server-reported total node count (`count`).
    public let totalCount: Int

    public init(lines: [String], start: String, end: String, totalCount: Int) {
        self.lines = lines
        self.start = start
        self.end = end
        self.totalCount = totalCount
    }
}

/// The full read-only journey payload the app renders.
public struct LearningGraph: Hashable, Codable, Sendable {
    public let buckets: [LearningGraphBucket]
    public let summary: LearningGraphSummary

    public init(buckets: [LearningGraphBucket], summary: LearningGraphSummary) {
        self.buckets = buckets
        self.summary = summary
    }

    /// Flat node list, bucket-chronological.
    public var nodes: [LearningGraphNode] {
        buckets.flatMap(\.nodes)
    }

    /// Skills count (legend "skills (N)").
    public var skillsCount: Int {
        nodes.filter { !$0.isMemory }.count
    }

    /// Memories count (legend "memories (N)").
    public var memoriesCount: Int {
        nodes.filter { $0.isMemory }.count
    }
}

/// All / Skills / Memories — the derivable filter set on this surface.
public enum MemoryGraphFilter: String, CaseIterable, Sendable, Identifiable {
    case all
    case skills
    case memories

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .skills: return "Skills"
        case .memories: return "Memories"
        }
    }

    public func includes(_ node: LearningGraphNode) -> Bool {
        switch self {
        case .all: return true
        case .skills: return !node.isMemory
        case .memories: return node.isMemory
        }
    }
}

/// `learning.detail {id}` result (learning_mutations.py:101-118).
public struct LearningNodeDetail: Hashable, Sendable {
    public let id: String
    /// "skill" | "memory" as the server reports it.
    public let kind: String
    public let label: String
    /// Full SKILL.md or raw memory chunk.
    public let content: String

    public init(id: String, kind: String, label: String, content: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.content = content
    }
}

/// Errors surfaced by the memory graph. Non-secret (spec §29 discipline).
public enum GatewayLearningError: Error, Sendable, Equatable, LocalizedError {
    /// The response body was not the expected shape.
    case malformedResponse(String)
    /// `learning.detail` came back `{ok: false, message}`.
    case nodeNotFound(String)
    /// A mutation (`learning.edit` / `learning.delete`) was refused by the
    /// gateway: `{ok: false, message}` (R10-T5). The message names the
    /// remedy (e.g. the curator unpin/restore recipe) and must reach the
    /// user verbatim.
    case mutationFailed(String)
    /// A transport/RPC failure (classified detail, non-secret).
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let detail):
            return "malformed gateway response (\(detail))"
        case .nodeNotFound(let detail):
            return "node not found (\(detail))"
        case .mutationFailed(let detail):
            return detail
        case .rpcFailed(let detail):
            return detail
        }
    }
}

/// R9-T7 seam: read-only learning graph over a gateway's transport.
/// Lives in FleetCore so FleetUI never imports FleetNetworking (M0 guard);
/// the concrete `GatewayLearningClient` is injected at the composition
/// root.
public protocol GatewayLearningProviding: Sendable {
    /// `learning.frames {cols: 60, rows: 20, frames: 2}` — the structured
    /// buckets/summary/axis payload (the pre-rendered grid runs are
    /// ignored; the app paints its own constellation).
    func learningGraph(profile: String?) async throws -> LearningGraph

    /// `learning.detail {id}` — full node content for the drill-in sheet.
    func nodeDetail(id: String) async throws -> LearningNodeDetail

    /// `learning.edit {id, content}` (R10-T5) — rewrite a node's content
    /// (full SKILL.md or raw memory chunk). Returns the gateway's success
    /// message ("updated …"); refusals throw `mutationFailed`.
    func editNode(id: String, content: String) async throws -> String

    /// `learning.delete {id}` (R10-T5) — remove a node. Skills are
    /// ARCHIVED server-side (the success message carries the curator
    /// restore recipe — surface it); refusals throw `mutationFailed`.
    func deleteNode(id: String) async throws -> String
}

/// Persistence seam for the offline snapshot (R9-T7): the VM depends on
/// this protocol; the composition root adapts FleetPersistence's
/// `SwiftDataCacheStore` (which conforms in an extension).
public protocol LearningGraphSnapshotStoring: Sendable {
    func save(_ graph: LearningGraph, for gatewayID: GatewayID, profile: ProfileSlug?) async throws
    func load(for gatewayID: GatewayID, profile: ProfileSlug?) async throws -> (graph: LearningGraph, capturedAt: Date)?
}

public extension LearningGraphSnapshotStoring {
    /// Legacy snapshots have unknown profile ownership and are never reused
    /// by a profile-qualified load. Kept only for existing unscoped callers.
    func save(_ graph: LearningGraph, for gatewayID: GatewayID) async throws {
        try await save(graph, for: gatewayID, profile: nil)
    }
    func load(for gatewayID: GatewayID) async throws -> (graph: LearningGraph, capturedAt: Date)? {
        try await load(for: gatewayID, profile: nil)
    }
}

/// Fail-closed default for gateways without a learning surface (no
/// endpoint configured): every call throws instead of silently pretending
/// the gateway answered (the `UnsupportedGatewayManagement` discipline).
public struct UnsupportedGatewayLearning: GatewayLearningProviding {
    public init() {}

    public func learningGraph(profile: String?) async throws -> LearningGraph {
        throw GatewayLearningError.rpcFailed("gateway not configured")
    }

    public func nodeDetail(id: String) async throws -> LearningNodeDetail {
        throw GatewayLearningError.rpcFailed("gateway not configured")
    }

    public func editNode(id: String, content: String) async throws -> String {
        throw GatewayLearningError.rpcFailed("gateway not configured")
    }

    public func deleteNode(id: String) async throws -> String {
        throw GatewayLearningError.rpcFailed("gateway not configured")
    }
}
