import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// R10-T3 — Projects browser view model:
/// - offline snapshot prefill (instant browse) then live refresh
/// - drill-in via projects.project_sessions merges hydrated lanes
/// - stale snapshot + live failure keeps the snapshot with an error banner
/// - empty tree is an honest empty state, not an error
/// - fail-closed seam (UnsupportedGatewayProjects) surfaces honestly
@MainActor
final class ProjectsBrowserTests: XCTestCase {

    // MARK: fixtures

    private func fixtureTree(activeID: String? = "proj-fleet") -> ProjectsTree {
        ProjectsTree(
            projects: [
                ProjectNode(
                    id: "__no_project__", label: "No Project", path: nil, color: nil,
                    isAuto: false, isNoProject: true, sessionCount: 1,
                    lastActive: 1_788_540_000, totalTokens: 500, totalCostUsd: 0.01,
                    repos: [
                        ProjectRepoNode(
                            id: "__no_project__", label: "No Project", path: nil, sessionCount: 1,
                            groups: [ProjectLaneNode(
                                id: "__no_project__", label: "No Project", path: nil,
                                isMain: false, isKanban: false, sessions: [])])],
                    previewSessions: [
                        ProjectSessionRow(
                            id: "s9", title: "Loose scratch chat", preview: "quick question",
                            startedAt: 1_788_530_000, lastActive: 1_788_540_000, endedAt: nil,
                            cwd: "/tmp", gitBranch: "", messageCount: 2, toolCallCount: 0,
                            inputTokens: 200, outputTokens: 300,
                            actualCostUsd: 0.01, estimatedCostUsd: nil,
                            model: "glm-5.3", profile: "default")]),
                ProjectNode(
                    id: "proj-fleet", label: "Fleet iOS",
                    path: "/Users/dev/code/fleet-ios", color: "#22d3ee",
                    isAuto: false, isNoProject: false, sessionCount: 3,
                    lastActive: 1_788_550_000, totalTokens: 1_500, totalCostUsd: 0.05,
                    repos: [
                        ProjectRepoNode(
                            id: "/Users/dev/code/fleet-ios", label: "fleet-ios",
                            path: "/Users/dev/code/fleet-ios", sessionCount: 3,
                            groups: [
                                ProjectLaneNode(
                                    id: "/Users/dev/code/fleet-ios::branch::r10-t3",
                                    label: "r10-t3", path: "/Users/dev/code/fleet-ios",
                                    isMain: false, isKanban: false, sessions: []),
                                ProjectLaneNode(
                                    id: "/Users/dev/code/fleet-ios::branch::main",
                                    label: "main", path: "/Users/dev/code/fleet-ios",
                                    isMain: true, isKanban: false, sessions: [])])],
                    previewSessions: [
                        ProjectSessionRow(
                            id: "s1", title: "WS transport fix", preview: "correlate rpc ids",
                            startedAt: 1_788_540_000, lastActive: 1_788_550_000, endedAt: nil,
                            cwd: "/Users/dev/code/fleet-ios", gitBranch: "r10-t3",
                            messageCount: 12, toolCallCount: 2, inputTokens: 600,
                            outputTokens: 900, actualCostUsd: 0.04, estimatedCostUsd: nil,
                            model: "glm-5.3", profile: "default"),
                        ProjectSessionRow(
                            id: "s2", title: "Reactions round 2", preview: "promote newest_role",
                            startedAt: 1_788_500_000, lastActive: 1_788_510_000, endedAt: nil,
                            cwd: "/Users/dev/code/fleet-ios", gitBranch: "main",
                            messageCount: 8, toolCallCount: 0, inputTokens: 100,
                            outputTokens: 200, actualCostUsd: 0.01, estimatedCostUsd: nil,
                            model: "glm-5.3", profile: "default")]),
            ],
            activeID: activeID,
            scopedSessionIDs: ["s9", "s1", "s2", "s3"])
    }

    private func hydratedProject() -> ProjectNode {
        ProjectNode(
            id: "proj-fleet", label: "Fleet iOS",
            path: "/Users/dev/code/fleet-ios", color: nil,
            isAuto: false, isNoProject: false, sessionCount: 1,
            lastActive: 1_788_550_000, totalTokens: 1_500, totalCostUsd: 0.05,
            repos: [
                ProjectRepoNode(
                    id: "/Users/dev/code/fleet-ios", label: "fleet-ios",
                    path: "/Users/dev/code/fleet-ios", sessionCount: 1,
                    groups: [
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::branch::r10-t3",
                            label: "r10-t3", path: "/Users/dev/code/fleet-ios",
                            isMain: false, isKanban: false,
                            sessions: [
                                ProjectSessionRow(
                                    id: "s1", title: "WS transport fix",
                                    preview: "correlate rpc ids",
                                    startedAt: 1_788_540_000, lastActive: 1_788_550_000,
                                    endedAt: nil, cwd: "/Users/dev/code/fleet-ios",
                                    gitBranch: "r10-t3", messageCount: 12, toolCallCount: 2,
                                    inputTokens: 600, outputTokens: 900,
                                    actualCostUsd: 0.04, estimatedCostUsd: nil,
                                    model: "glm-5.3", profile: "default")])])],
            previewSessions: [])
    }

    /// Scriptable seam double — records calls, returns queued results.
    /// (NSLock discipline: locking lives in SYNCHRONOUS helpers only —
    /// `lock` is unavailable from async contexts.)
    private final class SeamDouble: GatewayProjectsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _treeCalls = 0
        private var _drillCalls: [String] = []

        var treeResult: Result<ProjectsTree, Error> =
            .success(ProjectsTree(projects: [], activeID: nil, scopedSessionIDs: []))
        var drillResult: Result<ProjectNode?, Error> = .success(nil)

        private func recordTree() {
            lock.lock(); defer { lock.unlock() }
            _treeCalls += 1
        }

        private func recordDrill(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            _drillCalls.append(id)
        }

        var treeCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _treeCalls
        }

        var drillCalls: [String] {
            lock.lock(); defer { lock.unlock() }
            return _drillCalls
        }

        func projectTree(profile: String?) async throws -> ProjectsTree {
            recordTree()
            return try treeResult.get()
        }

        func projectSessions(projectID: String, profile: String?) async throws -> ProjectNode? {
            recordDrill(projectID)
            return try drillResult.get()
        }

        func completePath(word: String, cwd: String?) async throws -> [PathCompletionItem] { [] }
    }

    private final class FailingStore: ProjectsSnapshotStoring, @unchecked Sendable {
        func save(_ tree: ProjectsTree, for gatewayID: GatewayID) async throws {
            throw NSError(domain: "test", code: 1)
        }
        func load(for gatewayID: GatewayID) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
            nil
        }
    }

    // MARK: tree lifecycle

    func testStartPrefillsSnapshotThenLiveRefresh() async {
        let seam = SeamDouble()
        seam.treeResult = .success(fixtureTree())
        let store = InMemoryProjectsSnapshotStore()
        try? await store.save(fixtureTree(), for: GatewayID(rawValue: "<dev-workstation>"))

        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: store)
        await vm.start(profile: "default")

        XCTAssertEqual(vm.tree?.projects.count, 2)
        XCTAssertEqual(vm.source, .live, "successful live load settles the source as live")
        XCTAssertEqual(seam.treeCalls, 1)
        XCTAssertNil(vm.offlineCapturedAt, "capturedAt resets on live settle")
    }

    func testLiveFailureKeepsSnapshotAndSurfacesError() async {
        let seam = SeamDouble()
        seam.treeResult = .failure(GatewayProjectsError.rpcFailed("gateway not configured"))
        let store = InMemoryProjectsSnapshotStore()
        try? await store.save(fixtureTree(), for: GatewayID(rawValue: "<dev-workstation>"))

        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: store)
        await vm.start(profile: "default")

        XCTAssertEqual(vm.tree?.projects.count, 2, "snapshot prefill survives the live failure")
        XCTAssertEqual(vm.source, .offlineSnapshot)
        XCTAssertNotNil(vm.offlineCapturedAt)
        XCTAssertNotNil(vm.errorMessage, "failure is never silent")
    }

    func testEmptyTreeIsHonestEmptyStateNotError() async {
        let seam = SeamDouble()
        seam.treeResult = .success(ProjectsTree(projects: [], activeID: nil, scopedSessionIDs: []))
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        XCTAssertEqual(vm.tree?.projects.count, 0)
        XCTAssertNil(vm.errorMessage, "an empty profile DB is not an error (methods_config.py:128-131)")
    }

    func testFailClosedSeamSurfacesHonestError() async {
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: UnsupportedGatewayProjects(),
            snapshotStore: nil)
        await vm.start(profile: nil)
        XCTAssertNotNil(vm.errorMessage, "UnsupportedGatewayProjects must never silently pretend success")
        XCTAssertNil(vm.tree)
    }

    // MARK: drill-in

    func testDrillInMergesHydratedLanes() async {
        let seam = SeamDouble()
        seam.treeResult = .success(fixtureTree())
        seam.drillResult = .success(hydratedProject())
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: nil)
        await vm.start(profile: "default")

        await vm.openProject(id: "proj-fleet")

        XCTAssertEqual(seam.drillCalls, ["proj-fleet"])
        let detail = try! XCTUnwrap(vm.projectDetail)
        let hydrated = try! XCTUnwrap(detail.project)
        XCTAssertEqual(hydrated.id, "proj-fleet")
        XCTAssertEqual(hydrated.repos[0].groups[0].sessions.count, 1,
                       "hydrated lanes carry session rows the overview omitted")
        XCTAssertNil(detail.error)
    }

    func testDrillInUnknownProjectShowsHonestEmptyDetail() async {
        let seam = SeamDouble()
        seam.treeResult = .success(fixtureTree())
        seam.drillResult = .success(nil)
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: nil)
        await vm.start(profile: "default")

        await vm.openProject(id: "proj-fleet")
        let detail = try! XCTUnwrap(vm.projectDetail)
        XCTAssertNil(detail.project, "project:null decodes to an honest empty drill-in")
    }

    func testDrillInFailureSurfacesErrorAndKeepsOverview() async {
        let seam = SeamDouble()
        seam.treeResult = .success(fixtureTree())
        seam.drillResult = .failure(GatewayProjectsError.rpcFailed("profile db locked (5061)"))
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: nil)
        await vm.start(profile: "default")

        await vm.openProject(id: "proj-fleet")
        let detail = try! XCTUnwrap(vm.projectDetail, "the drill-in pane stays open with its error")
        XCTAssertNil(detail.project)
        XCTAssertEqual(detail.error, "profile db locked (5061)")
        XCTAssertNotNil(vm.tree, "the overview stays untouched by a drill-in failure")
    }

    // MARK: snapshot store

    func testLiveSuccessWritesSnapshotFailSoft() async {
        let seam = SeamDouble()
        seam.treeResult = .success(fixtureTree())
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            projects: seam,
            snapshotStore: FailingStore())
        await vm.start(profile: nil)
        XCTAssertNil(vm.errorMessage, "a persistence failure must not fail the pane (save-on-success is best-effort)")
        XCTAssertEqual(vm.source, .live)
    }
}

/// Minimal in-memory snapshot store for VM tests (lock discipline:
/// synchronous helpers only).
final class InMemoryProjectsSnapshotStore: ProjectsSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: (ProjectsTree, Date)] = [:]

    /// Synchronous storage access (lock unavailable in async contexts).
    private func storage(_ mutate: (inout [String: (ProjectsTree, Date)]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&rows)
    }

    func save(_ tree: ProjectsTree, for gatewayID: GatewayID) async throws {
        storage { rows in
            rows[gatewayID.rawValue] = (tree, Date())
        }
    }

    func load(for gatewayID: GatewayID) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
        var result: (ProjectsTree, Date)?
        storage { rows in
            result = rows[gatewayID.rawValue]
        }
        return result
    }
}
