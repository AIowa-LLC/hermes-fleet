import Foundation
import Observation
import SwiftUI
import FleetCore

/// R9-T7 — deterministic star-map layout for the memory graph.
///
/// DESIGN (ported principles from the desktop/TUI renderers,
/// agent/learning_graph_render.py — the age gradient and lead-in constants
/// come from the desktop source, not guessed):
/// - Nodes place on a seeded spiral keyed by STABLE node id — same fixture,
///   same positions, regardless of input ordering (layout determinism is
///   test-enforced).
/// - Radial arrangement: recency maps to distance-from-center (recent
///   toward the rim, like the desktop constellation) and ink alpha (AGE
///   gradient: old quiet, recent bright).
/// - 300-node render cap, MOST RECENT FIRST (the newest buckets survive);
///   the honest "showing N of M" label reports the cut.
public struct MemoryStarLayout: Sendable {
    /// Rendered node + resolved position in unit space (x/y ∈ 0…1 — the
    /// Canvas maps to its own size; positions are size-independent so the
    /// same fixture lays out identically on every device).
    public struct PlacedNode: Identifiable, Hashable, Sendable {
        public let node: LearningGraphNode
        public let x: Double
        public let y: Double
        /// Age-gradient ink (0…1) — the desktop recencyInk port.
        public let ink: Double

        public var id: String { node.id }
        public var isMemory: Bool { node.isMemory }
    }

    public let positions: [String: PlacedNode]
    public let orderedNodes: [PlacedNode]
    /// Honest total from the server (`count`), not the rendered subset.
    public let totalNodeCount: Int
    public let isCapped: Bool

    /// Desktop-render constants (learning_graph_render.py:23-31).
    private static let leadIn = 0.06
    private static let ageOldInk = 0.42
    private static let ageMidInk = 0.74
    private static let ageNewInk = 0.95
    private static let ageMid = 0.52
    public static let renderCap = 300

    public init(graph: LearningGraph, filter: MemoryGraphFilter, reveal: Double = 1.0) {
        let clampedReveal = min(max(reveal, 0), 1)
        // Chronological flat list — sort by bucket index so the layout is
        // deterministic regardless of the envelope's bucket ordering.
        let sortedBuckets = graph.buckets.sorted { $0.index < $1.index }
        totalNodeCount = graph.summary.totalCount

        // Scrub: cut buckets by reveal fraction (timeline semantics — a
        // partial reveal shows the journey UP TO that date).
        let bucketCount = max(sortedBuckets.count, 1)
        let visibleBuckets = Int((clampedReveal * Double(bucketCount)).rounded(.up))
        var visible: [LearningGraphNode] = []
        var index = 0
        for bucket in sortedBuckets {
            guard index < visibleBuckets else { break }
            visible.append(contentsOf: bucket.nodes)
            index += 1
        }

        // Filter, then cap MOST RECENT FIRST (stable: reverse-chronological
        // take, re-sorted chronological for the spiral walk).
        var filtered = visible.filter { filter.includes($0) }
        let needsCap = filtered.count > Self.renderCap
        if needsCap {
            filtered = Array(filtered.suffix(Self.renderCap))
        }
        isCapped = needsCap && totalNodeCount > filtered.count

        // Recency: chronological rank → 0…1 (oldest 0, newest 1); fallback
        // to bucket spread when a single node.
        let count = filtered.count
        var positions: [String: PlacedNode] = [:]
        var ordered: [PlacedNode] = []
        ordered.reserveCapacity(count)
        for (i, node) in filtered.enumerated() {
            let rank = count > 1 ? Double(i) / Double(count - 1) : 1.0
            let recency = Self.leadIn + (1 - Self.leadIn) * rank
            // Deterministic angle from a stable FNV-1a hash of the node id
            // (never the array index — insertion order must not matter).
            let angle = Self.stableAngle(node.id)
            // Radius: recent nodes sit toward the rim.
            let radius = 0.12 + 0.36 * recency
            let x = 0.5 + radius * cos(angle)
            let y = 0.5 + radius * sin(angle)
            let placed = PlacedNode(
                node: node,
                x: x,
                y: y,
                ink: Self.recencyInk(recency))
            positions[node.id] = placed
            ordered.append(placed)
        }
        self.positions = positions
        self.orderedNodes = ordered
    }

    /// Honest cap label ("showing 300 of 420"), nil when nothing was cut.
    public var capLabel: String? {
        guard isCapped else { return nil }
        return "showing \(orderedNodes.count) of \(totalNodeCount)"
    }

    /// Desktop recencyInk port (learning_graph_render.py:75-81).
    static func recencyInk(_ recency: Double) -> Double {
        let t = min(max(recency, 0), 1)
        if t <= ageMid {
            let p = smoothstep(t / ageMid)
            return ageOldInk + (ageMidInk - ageOldInk) * p
        }
        let p = smoothstep((t - ageMid) / (1 - ageMid))
        return ageMidInk + (ageNewInk - ageMidInk) * p
    }

    private static func smoothstep(_ p: Double) -> Double {
        let t = min(max(p, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// FNV-1a over the id → golden-angle-stepped angle. Deterministic,
    /// insertion-order independent, well-spread.
    private static func stableAngle(_ id: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Map the 64-bit space over many golden-angle turns (≈ 2.1e9 turns
        // of resolution) — adjacent ids spread across the circle.
        return Double(hash % 1_000_003) / 1_000_003.0 * 2 * .pi * 2_147
    }
}

/// R9-T7 — observable state for the read-only Memory Graph pane.
@MainActor
@Observable
public final class MemoryGraphViewModel {
    public enum Source: Equatable, Sendable {
        case live
        case offlineSnapshot
    }

    // MARK: Observable state

    public private(set) var graph: LearningGraph?
    public private(set) var source: Source = .live
    /// When the offline snapshot was captured (nil on live loads).
    public private(set) var offlineCapturedAt: Date?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Filter (All / Skills / Memories — the derivable set on this surface).
    public var filter: MemoryGraphFilter = .all {
        didSet { rebuildLayout() }
    }
    /// Timeline scrub position 0…1.
    public var reveal: Double = 1.0 {
        didSet { rebuildLayout() }
    }
    /// Current deterministic layout (nil before first load).
    public private(set) var layout: MemoryStarLayout?
    /// Drill-in detail (learning.detail).
    public private(set) var detail: LearningNodeDetail?
    public private(set) var isLoadingDetail = false
    public private(set) var detailError: String?

    // MARK: Mutations (R10-T5 — learning.edit / learning.delete)

    /// Gateway message from the last successful edit/delete ("updated …" /
    /// the curator restore recipe). Cleared when a new mutation starts.
    public private(set) var mutationMessage: String?
    /// Refusal/transport failure from the last edit/delete (verbatim —
    /// gateway messages name the remedy).
    public private(set) var mutationError: String?
    public private(set) var mutationInFlight = false

    // MARK: Dependencies

    public let gatewayID: GatewayID
    private let learning: any GatewayLearningProviding
    private let snapshotStore: (any LearningGraphSnapshotStoring)?

    public init(
        gatewayID: GatewayID,
        learning: any GatewayLearningProviding,
        snapshotStore: (any LearningGraphSnapshotStoring)? = nil
    ) {
        self.gatewayID = gatewayID
        self.learning = learning
        self.snapshotStore = snapshotStore
    }

    // MARK: Lifecycle

    /// Offline prefill first (instant browse), then the live fetch.
    public func start(profile: String?) async {
        if graph == nil, let store = snapshotStore,
           let cached = try? await store.load(for: gatewayID, profile: profile.map(ProfileSlug.init(rawValue:))) {
            graph = cached.graph
            offlineCapturedAt = cached.capturedAt
            source = .offlineSnapshot
            rebuildLayout()
        }
        await reload(profile: profile)
    }

    public func reload(profile: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await learning.learningGraph(profile: profile)
            graph = fresh
            source = .live
            offlineCapturedAt = nil
            errorMessage = nil
            rebuildLayout()
            if let store = snapshotStore {
                // Save-on-success; a persistence failure must not fail the
                // pane (offline browse is best-effort).
                try? await store.save(fresh, for: gatewayID, profile: profile.map(ProfileSlug.init(rawValue:)))
            }
        } catch {
            // Keep the snapshot prefill (if any) for offline browse; surface
            // the failure honestly.
            errorMessage = Self.describe(error)
        }
    }

    /// Test/scrub hook — rebuilds the layout at the current reveal.
    public func setReveal(_ value: Double) {
        reveal = value
    }

    public func loadDetail(for nodeID: String) async {
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            detail = try await learning.nodeDetail(id: nodeID)
        } catch {
            detail = nil
            detailError = Self.describe(error)
        }
    }

    public func dismissDetail() {
        detail = nil
        detailError = nil
    }

    /// Clear the last mutation outcome (message or refusal).
    public func clearMutationFeedback() {
        mutationMessage = nil
        mutationError = nil
    }

    /// `learning.edit {id, content}` then a graph reload — the map must
    /// reflect the server's truth (labels can change with content), not a
    /// locally-optimistic patch.
    public func performEdit(nodeID: String, content: String, profile: String? = nil) async {
        mutationInFlight = true
        mutationMessage = nil
        mutationError = nil
        defer { mutationInFlight = false }
        do {
            mutationMessage = try await learning.editNode(id: nodeID, content: content)
            await reload(profile: profile)
        } catch {
            mutationError = Self.describe(error)
        }
    }

    /// `learning.delete {id}` then a graph reload + snapshot refresh —
    /// the node must not linger in the map or the offline snapshot.
    /// Closes the drill-in sheet either way (refusal keeps the graph
    /// intact and shows the gateway's message).
    public func performDelete(nodeID: String, profile: String? = nil) async {
        mutationInFlight = true
        mutationMessage = nil
        mutationError = nil
        defer { mutationInFlight = false }
        do {
            mutationMessage = try await learning.deleteNode(id: nodeID)
            await reload(profile: profile)
            dismissDetail()
        } catch {
            mutationError = Self.describe(error)
        }
    }

    private func rebuildLayout() {
        guard let graph else {
            layout = nil
            return
        }
        layout = MemoryStarLayout(graph: graph, filter: filter, reveal: reveal)
    }

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}
