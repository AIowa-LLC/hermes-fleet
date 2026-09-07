import XCTest
@testable import FleetCore

/// R10-T3 round 2 — `@file:` tap-through path targeting: the tree must
/// resolve a transcript file reference to the project whose repo (or
/// project path) contains it, so ProjectsView can pre-highlight the
/// containing project and surface the target path contextually.
final class ProjectsPathMatchingTests: XCTestCase {

    private func repoPath(_ p: String) -> ProjectRepoNode {
        ProjectRepoNode(id: p, label: (p as NSString).lastPathComponent, path: p, sessionCount: 1, groups: [])
    }

    private func tree() -> ProjectsTree {
        ProjectsTree(
            projects: [
                ProjectNode(
                    id: "__no_project__", label: "No Project", path: nil, color: nil,
                    isAuto: false, isNoProject: true, sessionCount: 1,
                    lastActive: 1, totalTokens: 0, totalCostUsd: 0,
                    repos: [repoPath("/srv/misc")], previewSessions: []),
                ProjectNode(
                    id: "proj-other", label: "Other", path: "/Users/dev/code/other",
                    color: nil, isAuto: false, isNoProject: false, sessionCount: 1,
                    lastActive: 1, totalTokens: 0, totalCostUsd: 0,
                    repos: [repoPath("/Users/dev/code/other")], previewSessions: []),
                ProjectNode(
                    id: "proj-fleet", label: "Fleet iOS", path: "/Users/dev/code/fleet-ios",
                    color: "#22d3ee", isAuto: false, isNoProject: false, sessionCount: 3,
                    lastActive: 2, totalTokens: 0, totalCostUsd: 0,
                    repos: [
                        repoPath("/Users/dev/code/fleet-ios"),
                        ProjectRepoNode(id: "sub", label: "sub", path: nil, sessionCount: 0, groups: []),
                    ],
                    previewSessions: []),
            ],
            activeID: "proj-fleet",
            scopedSessionIDs: [])
    }

    // MARK: containing-project resolution

    func testAbsolutePathInsideRepoMatchesItsProject() {
        let node = tree().project(containingPath: "/Users/dev/code/fleet-ios/Packages/FleetUI/Foo.swift")
        XCTAssertEqual(node?.id, "proj-fleet",
                       "a file under the repo path resolves to the containing project")
    }

    func testProjectPathPrefixMatchesWhenRepoHasNoPath() {
        let node = tree().project(containingPath: "/Users/dev/code/fleet-ios/README.md")
        XCTAssertEqual(node?.id, "proj-fleet")
    }

    func testFolderRefWithTrailingSlashMatches() {
        let node = tree().project(containingPath: "/Users/dev/code/fleet-ios/Packages/")
        XCTAssertEqual(node?.id, "proj-fleet",
                       "folder refs carry trailing slashes; normalization must not break the match")
    }

    func testLongestPrefixWinsWhenPathsNest() {
        // /Users/dev/code is not a project root here, but nested repo
        // roots must pick the DEEPEST match, not the first.
        let nested = ProjectsTree(
            projects: [
                ProjectNode(
                    id: "outer", label: "outer", path: "/Users/dev/code", color: nil,
                    isAuto: false, isNoProject: false, sessionCount: 1,
                    lastActive: 1, totalTokens: 0, totalCostUsd: 0,
                    repos: [repoPath("/Users/dev/code")], previewSessions: []),
                ProjectNode(
                    id: "inner", label: "inner", path: "/Users/dev/code/fleet-ios", color: nil,
                    isAuto: false, isNoProject: false, sessionCount: 1,
                    lastActive: 2, totalTokens: 0, totalCostUsd: 0,
                    repos: [repoPath("/Users/dev/code/fleet-ios")], previewSessions: []),
            ],
            activeID: nil, scopedSessionIDs: [])
        let node = nested.project(containingPath: "/Users/dev/code/fleet-ios/src/a.swift")
        XCTAssertEqual(node?.id, "inner", "deepest repo prefix wins")
    }

    func testNoProjectTierNeverMatches() {
        let node = tree().project(containingPath: "/srv/misc/scratch.txt")
        XCTAssertNil(node, "the No Project tier must never be a tap-through target")
    }

    func testUnrelatedPathReturnsNil() {
        XCTAssertNil(tree().project(containingPath: "/opt/homebrew/etc/conf"))
    }

    func testRelativePathDoesNotBlindlyMatch() {
        XCTAssertNil(tree().project(containingPath: "Packages/FleetUI/Foo.swift"),
                     "a repo-RELATIVE ref has no resolvable root; nil (honest) beats a wrong highlight")
    }

    func testEmptyPathReturnsNil() {
        XCTAssertNil(tree().project(containingPath: ""))
        XCTAssertNil(tree().project(containingPath: "/"))
    }

    func testDotDotSegmentsNormalizeBeforeMatching() {
        let node = tree().project(containingPath: "/Users/dev/code/fleet-ios/Packages/../README.md")
        XCTAssertEqual(node?.id, "proj-fleet")
    }

    func testPrefixMustRespectSegmentBoundary() {
        XCTAssertNil(tree().project(containingPath: "/Users/dev/code/fleet-ios-extra/x.swift"),
                     "prefix match must not cross a path-segment boundary")
    }
}
