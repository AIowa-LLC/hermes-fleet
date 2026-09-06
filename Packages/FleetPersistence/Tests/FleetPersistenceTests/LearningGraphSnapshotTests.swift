import XCTest
import FleetCore
@testable import FleetPersistence

/// R9-T7 — learning-graph snapshot round-trip: save-on-fetch,
/// load-on-cold-start, replace semantics, fail-soft decode.
final class LearningGraphSnapshotTests: XCTestCase {

    private func makeStore() throws -> SwiftDataCacheStore {
        try SwiftDataCacheStore.makeInMemory()
    }

    private func fixtureGraph() -> LearningGraph {
        LearningGraph(
            buckets: [
                LearningGraphBucket(
                    index: 0, label: "3 Sep", date: "3 Sep 2026",
                    category: "software-development",
                    nodes: [
                        LearningGraphNode(
                            id: "test-driven-development",
                            label: "test-driven-development",
                            fullLabel: "test-driven-development",
                            isMemory: false,
                            meta: "software-development · 3 Sep 2026 · x12"),
                        LearningGraphNode(
                            id: "memory:profile:0",
                            label: "apple-dev profile memory",
                            fullLabel: "apple-dev profile memory",
                            isMemory: true,
                            meta: "profile memory · 3 Sep 2026",
                            body: "# apple-dev profile memory"),
                    ]),
                LearningGraphBucket(
                    index: 1, label: "4 Sep", date: "4 Sep 2026",
                    category: nil,
                    nodes: []),
            ],
            summary: LearningGraphSummary(
                lines: ["4 learned skills · 10 memories · 3 skill links"],
                start: "3 Sep 2026", end: "4 Sep 2026", totalCount: 14))
    }

    func testSnapshotRoundTripsIdenticalGraph() async throws {
        let store = try makeStore()
        let gateway = GatewayID(rawValue: "workstation")
        try await store.saveLearningGraphSnapshot(fixtureGraph(), for: gateway)

        let loaded = try await store.loadLearningGraphSnapshot(for: gateway)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.graph, fixtureGraph(),
                       "decoded snapshot must equal the saved graph (Codable round-trip)")
        XCTAssertEqual(loaded?.graph.summary.totalCount, 14)
        XCTAssertEqual(loaded?.graph.buckets.count, 2)
        XCTAssertEqual(loaded?.graph.nodes.first?.id, "test-driven-development")
    }

    func testSaveReplacesPriorSnapshotPerGateway() async throws {
        let store = try makeStore()
        let gateway = GatewayID(rawValue: "workstation")
        try await store.saveLearningGraphSnapshot(fixtureGraph(), for: gateway)

        var next = fixtureGraph()
        next = LearningGraph(
            buckets: [],
            summary: LearningGraphSummary(
                lines: [], start: "oldest", end: "now", totalCount: 0))
        // A hair later so capturedAt orders strictly.
        try await Task.sleep(for: .milliseconds(20))
        try await store.saveLearningGraphSnapshot(next, for: gateway)

        let loaded = try await store.loadLearningGraphSnapshot(for: gateway)
        XCTAssertEqual(loaded?.graph, next, "latest capture wins (replace semantics)")
        XCTAssertTrue(loaded?.graph.buckets.isEmpty ?? false)
    }

    func testLoadWithoutSnapshotReturnsNil() async throws {
        let store = try makeStore()
        let loaded = try await store.loadLearningGraphSnapshot(
            for: GatewayID(rawValue: "never-seen"))
        XCTAssertNil(loaded)
    }

    func testSnapshotsAreScopedPerGateway() async throws {
        let store = try makeStore()
        let mac = GatewayID(rawValue: "workstation")
        let arch = GatewayID(rawValue: "arch")
        try await store.saveLearningGraphSnapshot(fixtureGraph(), for: mac)
        try await store.saveLearningGraphSnapshot(
            LearningGraph(
                buckets: [],
                summary: LearningGraphSummary(lines: [], start: "oldest", end: "now", totalCount: 0)),
            for: arch)

        let macLoaded = try await store.loadLearningGraphSnapshot(for: mac)
        XCTAssertEqual(macLoaded?.graph.summary.totalCount, 14)
        let archLoaded = try await store.loadLearningGraphSnapshot(for: arch)
        XCTAssertEqual(archLoaded?.graph.summary.totalCount, 0)
    }

    func testDeleteRemovesOnlyThatGatewaySnapshot() async throws {
        let store = try makeStore()
        let mac = GatewayID(rawValue: "workstation")
        let arch = GatewayID(rawValue: "arch")
        try await store.saveLearningGraphSnapshot(fixtureGraph(), for: mac)
        try await store.saveLearningGraphSnapshot(fixtureGraph(), for: arch)

        try await store.deleteLearningGraphSnapshot(for: mac)
        let macLoaded = try await store.loadLearningGraphSnapshot(for: mac)
        XCTAssertNil(macLoaded)
        let archLoaded = try await store.loadLearningGraphSnapshot(for: arch)
        XCTAssertNotNil(archLoaded, "deleting one gateway's snapshot must not touch another's")
    }
}
