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
        func save(_ tree: ProjectsTree, for gatewayID: GatewayID, profile: ProfileSlug?) async throws {
            throw NSError(domain: "test", code: 1)
        }
        func load(for gatewayID: GatewayID, profile: ProfileSlug?) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
            nil
        }
    }

    // MARK: tree lifecycle

    func testStartPrefillsSnapshotThenLiveRefresh() async {
        let seam = SeamDouble()
        seam.treeResult = .success(fixtureTree())
        let store = InMemoryProjectsSnapshotStore()
        try? await store.save(fixtureTree(), for: GatewayID(rawValue: "workstation"), profile: ProfileSlug(rawValue: "default"))

        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
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
        try? await store.save(fixtureTree(), for: GatewayID(rawValue: "workstation"), profile: ProfileSlug(rawValue: "default"))

        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
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
            gatewayID: GatewayID(rawValue: "workstation"),
            projects: seam,
            snapshotStore: nil)
        await vm.start(profile: nil)

        XCTAssertEqual(vm.tree?.projects.count, 0)
        XCTAssertNil(vm.errorMessage, "an empty profile DB is not an error (methods_config.py:128-131)")
    }

    func testFailClosedSeamSurfacesHonestError() async {
        let vm = ProjectsBrowserViewModel(
            gatewayID: GatewayID(rawValue: "workstation"),
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
            gatewayID: GatewayID(rawValue: "workstation"),
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
            gatewayID: GatewayID(rawValue: "workstation"),
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
            gatewayID: GatewayID(rawValue: "workstation"),
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
            gatewayID: GatewayID(rawValue: "workstation"),
            projects: seam,
            snapshotStore: FailingStore())
        await vm.start(profile: nil)
        XCTAssertNil(vm.errorMessage, "a persistence failure must not fail the pane (save-on-success is best-effort)")
        XCTAssertEqual(vm.source, .live)
    }
}

// MARK: - R10-T3 round 2: @file: tap-through (QA round-1 defects 1+2)

/// The transcript `@file:`/`@folder:` parser (ConversationView.fileRefs)
/// — pure static function, previously untested (QA defect 2).
final class ConversationFileRefsTests: XCTestCase {

    func testExtractsFileAndFolderRefs() {
        let refs = ConversationView.fileRefs(
            in: "see @file:/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift and @folder:/Users/dev/code/fleet-ios/Packages/ notes")
        XCTAssertEqual(refs.map(\.displayPath),
                       ["/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift",
                        "/Users/dev/code/fleet-ios/Packages/"])
        XCTAssertEqual(refs.map(\.ref),
                       ["@file:/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift",
                        "@folder:/Users/dev/code/fleet-ios/Packages/"])
        XCTAssertEqual(refs.map(\.index), [0, 1], "indices are sequential per message")
    }

    func testRejectsUrlAndGitRefs() {
        let refs = ConversationView.fileRefs(
            in: "docs @url:https://example.com/a and source @git:https://github.com/org/repo")
        XCTAssertTrue(refs.isEmpty, "@url:/@git: vocabulary is not a path ref")
    }

    func testDelimitersEndThePath() {
        let refs = ConversationView.fileRefs(
            in: "fixed in @file:src/main.swift (see also @folder:docs/) later")
        XCTAssertEqual(refs.map(\.displayPath), ["src/main.swift", "docs/"],
                       "whitespace, ')' and ']' terminate the path value")
    }

    func testEmptyValueIsSkippedNotMatched() {
        let refs = ConversationView.fileRefs(in: "broken ref @file: here")
        XCTAssertTrue(refs.isEmpty, "an empty path value is not a ref")
    }

    func testPlainTextWithoutRefsIsEmpty() {
        XCTAssertTrue(ConversationView.fileRefs(in: "no references at all").isEmpty)
        XCTAssertTrue(ConversationView.fileRefs(in: "").isEmpty)
    }

    func testMultipleRefsInOneMessageKeepOrderAndUniqueIdentity() {
        let refs = ConversationView.fileRefs(in: "a @file:one.txt b @file:two.txt c @file:one.txt")
        XCTAssertEqual(refs.map(\.displayPath), ["one.txt", "two.txt", "one.txt"])
        XCTAssertEqual(Set(refs).count, 3, "index distinguishes duplicate paths for ForEach identity")
    }
}

/// The Projects route must CARRY the referenced path (QA defect 1: the
/// chip previously navigated to the browser root with no focus).
final class FleetScreenProjectsRouteTests: XCTestCase {

    func testProjectsRouteCarriesFocusPath() {
        let plain = FleetScreen.projects(GatewayID(rawValue: "workstation"))
        let focused = FleetScreen.projects(
            GatewayID(rawValue: "workstation"),
            focusPath: "/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift")
        XCTAssertNotEqual(plain, focused,
                          "a focused route is a distinct navigation value")
        XCTAssertEqual(
            focused,
            FleetScreen.projects(
                GatewayID(rawValue: "workstation"),
                focusPath: "/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift"))
        if case .projects(let gatewayID, _, let focusPath) = focused {
            XCTAssertEqual(gatewayID.rawValue, "workstation")
            XCTAssertEqual(focusPath, "/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift")
        } else {
            XCTFail("expected .projects case")
        }
    }

    func testFocusPathHashesIntoRouteValue() {
        var seen = Set<FleetScreen>()
        XCTAssertTrue(seen.insert(FleetScreen.projects(GatewayID(rawValue: "g"), focusPath: "a")).inserted)
        XCTAssertFalse(seen.insert(FleetScreen.projects(GatewayID(rawValue: "g"), focusPath: "a")).inserted,
                       "same focus path hashes equal")
        XCTAssertTrue(seen.insert(FleetScreen.projects(GatewayID(rawValue: "g"), focusPath: "b")).inserted,
                      "different focus path hashes distinct")
        XCTAssertTrue(seen.insert(FleetScreen.projects(GatewayID(rawValue: "g"))).inserted,
                      "nil focus is distinct from any focused value")
    }
}

/// Focus resolution in the browser: the containing project highlight is
/// a pure function of the loaded tree + carried focus path (deep prefix
/// matching lives in FleetCore.ProjectsPathMatchingTests).
@MainActor
final class ProjectsFocusTests: XCTestCase {

    private func fixtureTree() -> ProjectsTree {
        ProjectsTree(
            projects: [
                ProjectNode(
                    id: "proj-fleet", label: "Fleet iOS",
                    path: "/Users/dev/code/fleet-ios", color: nil,
                    isAuto: false, isNoProject: false, sessionCount: 3,
                    lastActive: 1, totalTokens: 0, totalCostUsd: 0,
                    repos: [
                        ProjectRepoNode(
                            id: "/Users/dev/code/fleet-ios", label: "fleet-ios",
                            path: "/Users/dev/code/fleet-ios", sessionCount: 3, groups: [])],
                    previewSessions: [])],
            activeID: "proj-fleet", scopedSessionIDs: [])
    }

    func testAbsoluteRefInsideRepoResolvesContainingProject() {
        let tree = fixtureTree()
        XCTAssertEqual(
            tree.project(containingPath: "/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift")?.id,
            "proj-fleet")
    }

    func testRelativeRefResolvesNilHonestly() {
        XCTAssertNil(fixtureTree().project(containingPath: "attachments/notes.png"),
                     "repo-relative refs have no resolvable root — nil, never a wrong highlight")
    }

    func testUnrelatedAbsoluteRefResolvesNil() {
        XCTAssertNil(fixtureTree().project(containingPath: "/opt/homebrew/etc/rc"))
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

    func save(_ tree: ProjectsTree, for gatewayID: GatewayID, profile: ProfileSlug?) async throws {
        storage { rows in
            rows[gatewayID.rawValue + "#" + (profile?.rawValue ?? "<unknown>")] = (tree, Date())
        }
    }

    func load(for gatewayID: GatewayID, profile: ProfileSlug?) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
        var result: (ProjectsTree, Date)?
        storage { rows in
            result = rows[gatewayID.rawValue + "#" + (profile?.rawValue ?? "<unknown>")]
        }
        return result
    }
}
