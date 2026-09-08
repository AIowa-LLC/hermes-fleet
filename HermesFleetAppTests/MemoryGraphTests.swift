import XCTest
@testable import FleetUI
import FleetCore

/// R9-T7 — Memory Graph view model + layout engine:
/// - deterministic star layout (same fixture → same positions, order-independent)
/// - 300-node render cap with honest "showing N of M"
/// - All/Skills/Memories filter derived from node kind
/// - timeline scrubber cuts buckets by index
/// - snapshot save-on-success (offline browse)
///
/// The VM is @MainActor (Observable UI state) — every test hops to the main
/// actor to construct/drive it (Swift 6 isolation).
@MainActor
final class MemoryGraphTests: XCTestCase {

    // MARK: fixtures

    private func fixtureGraph(nodeCount: Int = 24) -> LearningGraph {
        var buckets: [LearningGraphBucket] = []
        var remaining = nodeCount
        var slice = 0
        while remaining > 0 {
            let take = min(3, remaining)
            remaining -= take
            var nodes: [LearningGraphNode] = []
            for n in 0..<take {
                let isMemory = (slice + n) % 3 == 0
                nodes.append(LearningGraphNode(
                    id: isMemory ? "memory:profile:\(slice)-\(n)" : "skill-\(slice)-\(n)",
                    label: isMemory ? "mem \(slice).\(n)" : "skill-\(slice).\(n)",
                    fullLabel: isMemory ? "memory \(slice).\(n)" : "skill-\(slice).\(n)",
                    isMemory: isMemory,
                    meta: "cat · \(slice) Sep 2026",
                    body: isMemory ? "chunk body" : ""))
            }
            buckets.append(LearningGraphBucket(
                index: slice, label: "\(3 + slice) Sep", date: "2026-09-\(3 + slice)",
                category: slice % 2 == 0 ? "dev" : "hermes", nodes: nodes))
            slice += 1
        }
        return LearningGraph(
            buckets: buckets,
            summary: LearningGraphSummary(
                lines: ["\(nodeCount / 3 * 2) learned skills · \(nodeCount / 3) memories"],
                start: "3 Sep 2026", end: "\(3 + slice - 1) Sep 2026",
                totalCount: nodeCount))
    }

    // MARK: layout determinism

    func testLayoutIsDeterministicForSameFixture() {
        let graph = fixtureGraph()
        let a = MemoryStarLayout(graph: graph, filter: .all)
        let b = MemoryStarLayout(graph: graph, filter: .all)
        XCTAssertEqual(a.positions.keys, b.positions.keys)
        for (id, pa) in a.positions {
            let pb = b.positions[id]!
            XCTAssertEqual(pa.x, pb.x, accuracy: 0.0001, "position x for \(id) must be identical")
            XCTAssertEqual(pa.y, pb.y, accuracy: 0.0001, "position y for \(id) must be identical")
        }
    }

    func testLayoutIsDeterministicRegardlessOfBucketOrder() {
        // Same nodes, reversed bucket order: layout keyed by stable node
        // identity + index-sorted buckets must be identical.
        let graph = fixtureGraph()
        let shuffled = LearningGraph(buckets: graph.buckets.reversed(), summary: graph.summary)
        let a = MemoryStarLayout(graph: graph, filter: .all)
        let b = MemoryStarLayout(graph: shuffled, filter: .all)
        XCTAssertEqual(a.positions.count, b.positions.count)
        for (id, pa) in a.positions {
            guard let pb = b.positions[id] else {
                XCTFail("node \(id) missing from shuffled layout")
                continue
            }
            XCTAssertEqual(pa.x, pb.x, accuracy: 0.0001, "shuffled input must not move \(id)")
            XCTAssertEqual(pa.y, pb.y, accuracy: 0.0001)
        }
    }

    // MARK: render cap

    func testLayoutCapsAt300MostRecentNodes() {
        let big = fixtureGraph(nodeCount: 420)
        let layout = MemoryStarLayout(graph: big, filter: .all)
        XCTAssertLessThanOrEqual(layout.positions.count, 300,
                                 "rendered node cap (Canvas perf on phone)")
        XCTAssertEqual(layout.totalNodeCount, 420,
                       "honest total comes from the server count")
        XCTAssertTrue(layout.isCapped,
                      "capped state drives the 'showing N of M' label")
        // The cap keeps the MOST RECENT nodes: the newest bucket's nodes
        // survive.
        let newestNodes = big.buckets.last?.nodes ?? []
        for node in newestNodes {
            XCTAssertNotNil(layout.positions[node.id],
                            "newest node \(node.id) must survive the cap")
        }
    }

    func testCapLabelReportsShowingNOfM() {
        let big = fixtureGraph(nodeCount: 420)
        let layout = MemoryStarLayout(graph: big, filter: .all)
        XCTAssertEqual(layout.capLabel, "showing 300 of 420")
    }

    func testUnderCapGraphReportsNoCapLabel() {
        let small = fixtureGraph(nodeCount: 24)
        let layout = MemoryStarLayout(graph: small, filter: .all)
        XCTAssertNil(layout.capLabel)
        XCTAssertFalse(layout.isCapped)
    }

    // MARK: filter

    func testFilterSkillsOnlyExcludesMemories() {
        let graph = fixtureGraph(nodeCount: 24)
        let layout = MemoryStarLayout(graph: graph, filter: .skills)
        XCTAssertTrue(layout.positions.values.allSatisfy { !$0.isMemory })
        XCTAssertFalse(layout.positions.isEmpty)
    }

    func testFilterMemoriesOnlyExcludesSkills() {
        let graph = fixtureGraph(nodeCount: 24)
        let layout = MemoryStarLayout(graph: graph, filter: .memories)
        XCTAssertTrue(layout.positions.values.allSatisfy(\.isMemory))
        XCTAssertFalse(layout.positions.isEmpty)
    }

    // MARK: scrubber

    func testScrubRevealCutsBucketsChronologically() async throws {
        let graph = fixtureGraph(nodeCount: 24) // 8 buckets
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: ScriptedLearningSeam(graph: graph),
            snapshotStore: nil)
        await vm.start(profile: nil)

        // Full reveal: all nodes.
        vm.setReveal(1.0)
        XCTAssertEqual(vm.layout?.positions.count ?? 0, 24)

        // Half reveal: only the first ~half of the buckets' nodes show.
        vm.setReveal(0.5)
        XCTAssertEqual(vm.layout?.positions.count ?? 0, 12,
                       "8 buckets × 3 nodes, half reveal = 4 buckets = 12 nodes")

        // Zero reveal: nothing.
        vm.setReveal(0.0)
        XCTAssertEqual(vm.layout?.positions.count ?? 0, 0)
    }

    // MARK: view model

    func testViewModelLoadsGraphAndSavesSnapshot() async throws {
        let graph = fixtureGraph(nodeCount: 12)
        let seam = ScriptedLearningSeam(graph: graph)
        let store = InMemorySnapshotStore()
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: store)
        await vm.start(profile: "default")

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.graph, graph)
        XCTAssertEqual(seam.requestedProfile, "default")
        let saved = await store.saved
        XCTAssertEqual(saved?.graph, graph, "successful load persists the snapshot")
        XCTAssertNotNil(saved?.capturedAt)
    }

    func testViewModelSurfacesErrorWithNoFabricatedGraph() async throws {
        let seam = FailingLearningSeam()
        let store = InMemorySnapshotStore()
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: store)
        await vm.start(profile: nil)

        XCTAssertNotNil(vm.errorMessage, "load failure surfaces honestly")
        XCTAssertNil(vm.graph, "no fabricated graph on failure")
    }

    func testViewModelOfflinePrefillsFromSnapshotThenStillTriesNetwork() async throws {
        let graph = fixtureGraph(nodeCount: 12)
        let seam = FailingLearningSeam()
        let store = InMemorySnapshotStore()
        try await store.save(graph, for: GatewayID(rawValue: "workstation"))
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: store)
        await vm.start(profile: nil)

        // The snapshot prefills the offline browse surface…
        XCTAssertEqual(vm.graph, graph, "snapshot prefill on cold start")
        // …and the network failure is still surfaced (not hidden).
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.source, .offlineSnapshot)
    }

    func testNodeDetailLoadsThroughViewModel() async throws {
        let graph = fixtureGraph(nodeCount: 12)
        let seam = ScriptedLearningSeam(graph: graph)
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        await vm.loadDetail(for: "skill-0-0")
        XCTAssertEqual(vm.detail?.id, "skill-0-0")
        XCTAssertEqual(vm.detail?.content, "SKILL.md fixture body")
    }

    // MARK: edit / delete (R10-T5)

    func testEditNodeReloadsGraphAndSurfacesMessage() async throws {
        let seam = ScriptedLearningSeam(graph: fixtureGraph(nodeCount: 12))
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        await vm.performEdit(nodeID: "memory:profile:0-0", content: "# rewritten")

        XCTAssertEqual(seam.edited?.id, "memory:profile:0-0")
        XCTAssertEqual(seam.edited?.content, "# rewritten")
        XCTAssertEqual(vm.mutationMessage, "updated memory in MEMORY.md")
        XCTAssertNil(vm.mutationError)
        XCTAssertEqual(vm.mutationInFlight, false)
        // The graph reloaded after the successful mutation (fresh buckets).
        XCTAssertEqual(vm.source, .live)
    }

    func testEditNodeSurfacesRefusalVerbatimWithoutReload() async throws {
        let seam = ScriptedLearningSeam(graph: fixtureGraph(nodeCount: 12))
        seam.editRefusal = "empty memory — use delete to remove it"
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        await vm.performEdit(nodeID: "memory:profile:0-0", content: "  ")

        XCTAssertEqual(
            vm.mutationError,
            "empty memory — use delete to remove it",
            "the gateway's remedy message must surface verbatim")
        XCTAssertNil(vm.mutationMessage)
    }

    func testDeleteNodeReloadsGraphWithoutDeletedNode() async throws {
        let seam = ScriptedLearningSeam(graph: fixtureGraph(nodeCount: 12))
        let store = InMemorySnapshotStore()
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: store)
        await vm.start(profile: nil)
        let before = vm.layout?.positions.count ?? 0
        XCTAssertEqual(before, 12)

        await vm.performDelete(nodeID: "memory:profile:0-0", profile: nil)

        XCTAssertEqual(seam.deletedID, "memory:profile:0-0")
        XCTAssertEqual(vm.mutationMessage, "deleted memory from MEMORY.md")
        XCTAssertNil(vm.detail, "the drill-in sheet closes after delete")
        XCTAssertNil(
            vm.graph?.nodes.first { $0.id == "memory:profile:0-0" },
            "the deleted node must vanish from the reloaded graph")
        XCTAssertEqual(vm.layout?.positions.count ?? 0, 11)
        // The snapshot reflects the post-delete graph (no zombie offline).
        let saved = await store.saved
        XCTAssertNil(saved?.graph.nodes.first { $0.id == "memory:profile:0-0" })
    }

    func testDeleteNodeSurfacesRefusalVerbatim() async throws {
        let seam = ScriptedLearningSeam(graph: fixtureGraph(nodeCount: 12))
        seam.deleteRefusal =
            "'apple-product-factory' is pinned — unpin it first (hermes curator unpin apple-product-factory)"
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
            learning: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        await vm.performDelete(nodeID: "apple-product-factory", profile: nil)

        XCTAssertEqual(
            vm.mutationError,
            "'apple-product-factory' is pinned — unpin it first (hermes curator unpin apple-product-factory)")
        XCTAssertNil(vm.mutationMessage)
        XCTAssertEqual(vm.layout?.positions.count ?? 0, 12,
                       "a refused delete must not change the rendered graph")
    }
}

// MARK: - test doubles

final class ScriptedLearningSeam: GatewayLearningProviding, @unchecked Sendable {
    private let graphBox: MutexBox<LearningGraph>
    private let profileBox = MutexBox<String?>(nil as String?)
    private let editBox = MutexBox<(id: String, content: String)?>(nil as (id: String, content: String)?)
    private let deleteBox = MutexBox<String?>(nil as String?)
    /// Set before a call to make the next edit/delete refuse (mirrors the
    /// gateway's `{ok: false, message}` refusal shape).
    var editRefusal: String?
    var deleteRefusal: String?

    init(graph: LearningGraph) {
        self.graphBox = MutexBox(graph)
    }

    var requestedProfile: String? {
        profileBox.read()
    }

    var edited: (id: String, content: String)? {
        editBox.read()
    }

    var deletedID: String? {
        deleteBox.read()
    }

    func learningGraph(profile: String?) async throws -> LearningGraph {
        profileBox.write(profile)
        return graphBox.read()
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
        LearningNodeDetail(id: id, kind: "skill", label: id, content: "SKILL.md fixture body")
    }

    func editNode(id: String, content: String) async throws -> String {
        editBox.write((id, content))
        if let editRefusal {
            throw GatewayLearningError.mutationFailed(editRefusal)
        }
        return "updated memory in MEMORY.md"
    }

    func deleteNode(id: String) async throws -> String {
        deleteBox.write(id)
        if let deleteRefusal {
            throw GatewayLearningError.mutationFailed(deleteRefusal)
        }
        // Mirror the live gateway: the deleted node vanishes from the graph.
        let old = graphBox.read()
        let next = LearningGraph(
            buckets: old.buckets.map { bucket in
                LearningGraphBucket(
                    index: bucket.index, label: bucket.label, date: bucket.date,
                    category: bucket.category,
                    nodes: bucket.nodes.filter { $0.id != id })
            },
            summary: old.summary)
        graphBox.write(next)
        return "deleted memory from MEMORY.md"
    }
}

final class FailingLearningSeam: GatewayLearningProviding, @unchecked Sendable {
    func learningGraph(profile: String?) async throws -> LearningGraph {
        throw GatewayLearningError.rpcFailed("gateway unreachable")
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
        throw GatewayLearningError.rpcFailed("gateway unreachable")
    }

    func editNode(id: String, content: String) async throws -> String {
        throw GatewayLearningError.rpcFailed("gateway unreachable")
    }

    func deleteNode(id: String) async throws -> String {
        throw GatewayLearningError.rpcFailed("gateway unreachable")
    }
}

/// Async-safe mutex wrapper for test doubles (NSLock is unavailable in
/// async contexts on this toolchain).
final class MutexBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func write(_ next: Value) {
        lock.lock(); defer { lock.unlock() }
        value = next
    }
}

/// In-memory LearningGraphSnapshotStore double (the VM takes the protocol;
/// the composition root adapts the SwiftData store).
final class InMemorySnapshotStore: LearningGraphSnapshotStoring, @unchecked Sendable {
    private let box = MutexBox<(graph: LearningGraph, capturedAt: Date)?>(nil)

    var saved: (graph: LearningGraph, capturedAt: Date)? {
        box.read()
    }

    func save(_ graph: LearningGraph, for gatewayID: GatewayID, profile: ProfileSlug?) async throws {
        box.write((graph, Date()))
    }

    func load(for gatewayID: GatewayID, profile: ProfileSlug?) async throws -> (graph: LearningGraph, capturedAt: Date)? {
        box.read()
    }
}
