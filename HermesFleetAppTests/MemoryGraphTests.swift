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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
        try await store.save(graph, for: GatewayID(rawValue: "<dev-workstation>"))
        let vm = MemoryGraphViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            learning: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        await vm.loadDetail(for: "skill-0-0")
        XCTAssertEqual(vm.detail?.id, "skill-0-0")
        XCTAssertEqual(vm.detail?.content, "SKILL.md fixture body")
    }
}

// MARK: - test doubles

final class ScriptedLearningSeam: GatewayLearningProviding, @unchecked Sendable {
    private let graph: LearningGraph
    private let box = MutexBox<String?>(nil as String?)

    init(graph: LearningGraph) {
        self.graph = graph
    }

    var requestedProfile: String? {
        box.read()
    }

    func learningGraph(profile: String?) async throws -> LearningGraph {
        box.write(profile)
        return graph
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
        LearningNodeDetail(id: id, kind: "skill", label: id, content: "SKILL.md fixture body")
    }
}

final class FailingLearningSeam: GatewayLearningProviding, @unchecked Sendable {
    func learningGraph(profile: String?) async throws -> LearningGraph {
        throw GatewayLearningError.rpcFailed("gateway unreachable")
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
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

    func save(_ graph: LearningGraph, for gatewayID: GatewayID) async throws {
        box.write((graph, Date()))
    }

    func load(for gatewayID: GatewayID) async throws -> (graph: LearningGraph, capturedAt: Date)? {
        box.read()
    }
}
