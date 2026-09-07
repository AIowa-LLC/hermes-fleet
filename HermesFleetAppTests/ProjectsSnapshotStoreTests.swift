import XCTest
import FleetCore
import FleetPersistence
@testable import FleetPersistence

/// R10-T3 — ProjectsSnapshotRow round-trip through the real SwiftData
/// in-memory container (the LearningGraphSnapshot discipline: replace
/// semantics per gateway, latest-wins, fail-soft decode).
final class ProjectsSnapshotStoreTests: XCTestCase {

    func testRoundTripSavesAndLoadsLatest() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let gateway = GatewayID(rawValue: "workstation")
        let tree = ProjectsTree(
            projects: [
                ProjectNode(
                    id: "proj-fleet", label: "Fleet iOS",
                    path: "/Users/dev/code/fleet-ios", color: nil,
                    isAuto: false, isNoProject: false, sessionCount: 1,
                    lastActive: 1_788_550_000, totalTokens: 10, totalCostUsd: 0.01,
                    repos: [], previewSessions: []),
            ],
            activeID: "proj-fleet",
            scopedSessionIDs: ["s1"])

        try await store.saveProjectsSnapshot(tree, for: gateway)
        let loaded = try await store.loadProjectsSnapshot(for: gateway)

        let (graph, _) = try XCTUnwrap(loaded, "snapshot must round-trip")
        XCTAssertEqual(graph, tree, "decoded snapshot equals the saved tree")
    }

    func testReplaceSemanticsOneRowPerGateway() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let gateway = GatewayID(rawValue: "workstation")
        let first = ProjectsTree(projects: [], activeID: nil, scopedSessionIDs: [])
        var second = first
        second = ProjectsTree(
            projects: [], activeID: "proj-2", scopedSessionIDs: [])

        try await store.saveProjectsSnapshot(first, for: gateway)
        try await store.saveProjectsSnapshot(second, for: gateway)

        let loaded = try await store.loadProjectsSnapshot(for: gateway)
        XCTAssertEqual(loaded?.tree.activeID, "proj-2", "latest snapshot wins — no duplicate rows")
    }

    func testLoadReturnsNilForUnknownGateway() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let loaded = try await store.loadProjectsSnapshot(for: GatewayID(rawValue: "never-seen"))
        XCTAssertNil(loaded)
    }
}
