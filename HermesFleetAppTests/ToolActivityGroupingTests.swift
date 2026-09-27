import XCTest
import FleetCore
import FleetUI

/// FB5 (TestFlight Build 90 feedback #5 — "Too much room for tool calling."
/// / "It should look more a chat than technical reporting."): pure unit
/// tests for `ToolActivityGrouping`, the function that folds consecutive
/// COMPLETED tool calls (and absorbed completed reasoning) into one compact
/// transcript block. No view, no view model — only `ConversationRow` values
/// in, `[TranscriptBlock]` out.
final class ToolActivityGroupingTests: XCTestCase {

    // MARK: - Fixtures

    private func toolRow(
        _ id: String, name: String, detail: String? = "done",
        inFlight: Bool = false, isFailed: Bool = false,
        artifacts: [ArtifactReference]? = nil,
        generationActivity: ImageGenerationActivity? = nil
    ) -> ConversationRow {
        var row = ConversationRow(
            id: id, kind: .tool, text: name, detail: detail,
            isFailed: isFailed, toolIsInFlight: inFlight)
        row.artifacts = artifacts
        row.generationActivity = generationActivity
        return row
    }

    private func userRow(_ id: String, text: String = "hi") -> ConversationRow {
        ConversationRow(id: id, kind: .user, text: text)
    }

    private func assistantRow(_ id: String, text: String, isStreaming: Bool = false) -> ConversationRow {
        ConversationRow(id: id, kind: .assistant, text: text, isStreaming: isStreaming)
    }

    /// A completed reasoning aside — a textless, non-streaming assistant row
    /// carrying only reasoning detail.
    private func reasoningRow(_ id: String, detail: String) -> ConversationRow {
        ConversationRow(id: id, kind: .assistant, text: "", detail: detail, isStreaming: false)
    }

    // MARK: - 4 completed tools → 1 group

    func testFourCompletedToolsCollapseToOneGroup() {
        let rows = [
            userRow("u1"),
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "memory"),
            toolRow("t3", name: "browser"),
            toolRow("t4", name: "editor"),
            assistantRow("a1", text: "Done."),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 3, "user row, one tool group, assistant row")
        XCTAssertEqual(blocks[0].id, "u1")
        guard case .toolGroup(let group) = blocks[1] else {
            return XCTFail("expected a toolGroup block")
        }
        XCTAssertEqual(group.totalCount, 4)
        XCTAssertEqual(group.toolRows.map(\.id), ["t1", "t2", "t3", "t4"])
        XCTAssertEqual(blocks[2].id, "a1")
    }

    // MARK: - In-flight tool is never grouped

    func testInFlightToolNeverGroups() {
        let rows = [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "memory", inFlight: true),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        // The completed tool folds alone into a group; the in-flight tool
        // stays a live row of its own — a working session never reads idle.
        XCTAssertEqual(blocks.count, 2)
        guard case .toolGroup(let group) = blocks[0] else {
            return XCTFail("expected the completed tool to fold into a group")
        }
        XCTAssertEqual(group.totalCount, 1)
        guard case .row(let liveRow) = blocks[1] else {
            return XCTFail("expected the in-flight tool as its own row")
        }
        XCTAssertEqual(liveRow.id, "t2")
        XCTAssertTrue(liveRow.toolIsInFlight)
    }

    // MARK: - Failure stays visible

    func testFailedToolStaysVisibleInsideGroup() {
        let rows = [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "memory", isFailed: true),
            toolRow("t3", name: "browser"),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 1)
        guard case .toolGroup(let group) = blocks[0] else {
            return XCTFail("expected one toolGroup")
        }
        XCTAssertEqual(group.totalCount, 3)
        XCTAssertEqual(group.failedCount, 1)
        XCTAssertFalse(group.isAllSucceeded)
        // The failure is never hidden inside a clean-looking summary.
        XCTAssertEqual(group.summaryLine, "Used 3 tools · 1 failed")
        XCTAssertTrue(group.rows.contains { $0.id == "t2" })
    }

    // MARK: - Approval-shaped rows are never grouped

    func testNonToolRowIsNeverGrouped() {
        // Approvals never appear in the transcript row list at all (they
        // render through the separate approval banner/VM) — modeled here by
        // any non-tool row breaking the run, which is the mechanism that
        // keeps them from ever being folded if that ever changed.
        let rows = [
            toolRow("t1", name: "terminal"),
            ConversationRow(id: "s1", kind: .system, text: "Approval needed"),
            toolRow("t2", name: "memory"),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 3)
        guard case .row(let systemRow) = blocks[1] else {
            return XCTFail("expected the non-tool row to stay its own block")
        }
        XCTAssertEqual(systemRow.kind, .system)
    }

    // MARK: - Artifact / image-generation rows are preserved exactly

    func testArtifactRowNeverFoldsIntoGroup() {
        let rows = [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "image_generate", artifacts: [
                ArtifactReference(
                    gatewayID: GatewayID(rawValue: "workstation"), sessionID: "s1",
                    profile: "default", path: "/home/u/.hermes/cache/images/scripted_generation.png")
            ]),
            toolRow("t3", name: "memory"),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        // The artifact row splits the run into two groups around it.
        XCTAssertEqual(blocks.count, 3)
        guard case .row(let artifactRow) = blocks[1] else {
            return XCTFail("expected the artifact row preserved as its own block")
        }
        XCTAssertEqual(artifactRow.id, "t2")
        XCTAssertNotNil(artifactRow.artifacts)
    }

    func testInFlightGenerationRowNeverFoldsIntoGroup() {
        let rows = [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "image_generate", generationActivity: .generating(toolID: "t2")),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 2)
        guard case .row(let generatingRow) = blocks[1] else {
            return XCTFail("expected the generating row preserved as its own block")
        }
        XCTAssertEqual(generatingRow.generationActivity, .generating(toolID: "t2"))
    }

    // MARK: - Reasoning between tools, once completed, is absorbed

    func testCompletedReasoningBetweenToolsIsAbsorbed() {
        let rows = [
            toolRow("t1", name: "terminal"),
            reasoningRow("r1", detail: "Deciding what to check next…"),
            toolRow("t2", name: "memory"),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 1, "the reasoning aside never breaks the run")
        guard case .toolGroup(let group) = blocks[0] else {
            return XCTFail("expected one toolGroup")
        }
        XCTAssertEqual(group.totalCount, 2, "the reasoning aside is not itself a tool call")
        XCTAssertTrue(group.rows.contains { $0.id == "r1" }, "absorbed, not dropped")
    }

    /// A streaming (not-yet-completed) reasoning aside must never be
    /// swallowed — only a COMPLETED aside absorbs.
    func testStreamingReasoningIsNotAbsorbed() {
        let rows = [
            toolRow("t1", name: "terminal"),
            ConversationRow(id: "r1", kind: .assistant, text: "", detail: "still thinking", isStreaming: true),
            toolRow("t2", name: "memory"),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        // The streaming aside breaks the run into two groups around it.
        XCTAssertEqual(blocks.count, 3)
        guard case .row(let streamingRow) = blocks[1] else {
            return XCTFail("expected the streaming aside preserved as its own block")
        }
        XCTAssertTrue(streamingRow.isStreaming)
    }

    // MARK: - Separate turns are never merged

    func testSeparateTurnsAreNeverMerged() {
        let rows = [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "memory"),
            assistantRow("a1", text: "First answer."),
            userRow("u2", text: "again"),
            toolRow("t3", name: "terminal"),
            toolRow("t4", name: "memory"),
            assistantRow("a2", text: "Second answer."),
        ]
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 5)
        guard case .toolGroup(let firstGroup) = blocks[0],
              case .toolGroup(let secondGroup) = blocks[3] else {
            return XCTFail("expected two distinct tool groups, one per turn")
        }
        XCTAssertEqual(firstGroup.toolRows.map(\.id), ["t1", "t2"])
        XCTAssertEqual(secondGroup.toolRows.map(\.id), ["t3", "t4"])
    }

    // MARK: - Deterministic summary text

    func testSummaryTextIsDeterministic() {
        let rows = [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "memory"),
            toolRow("t3", name: "browser"),
            toolRow("t4", name: "editor"),
        ]
        let group = ToolActivityGroup(rows: rows)
        XCTAssertEqual(group.toolNameSummary, "terminal, memory +2")
        XCTAssertEqual(group.summaryLine, "Used 4 tools · terminal, memory +2")
        XCTAssertEqual(group.accessibilitySummary, "Used 4 tools: terminal, memory, and 2 more.")
    }

    func testSummaryTextWithTwoOrFewerUniqueNamesHasNoPlusSuffix() {
        let group = ToolActivityGroup(rows: [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "memory"),
        ])
        XCTAssertEqual(group.toolNameSummary, "terminal, memory")
        XCTAssertEqual(group.summaryLine, "Used 2 tools · terminal, memory")
    }

    func testSummaryTextWithRepeatedSingleNameDedupes() {
        let group = ToolActivityGroup(rows: [
            toolRow("t1", name: "terminal"),
            toolRow("t2", name: "terminal"),
            toolRow("t3", name: "terminal"),
        ])
        XCTAssertEqual(group.toolNames, ["terminal"])
        XCTAssertEqual(group.toolNameSummary, "terminal")
        XCTAssertEqual(group.summaryLine, "Used 3 tools · terminal")
    }

    // MARK: - Density: many rows collapse to one block

    func testSixToolTurnCollapsesToOneBlock() {
        let rows = (0..<6).map { toolRow("t\($0)", name: "tool\($0)") }
        let blocks = ToolActivityGrouping.group(rows)
        XCTAssertEqual(blocks.count, 1, "6 rendered rows drop to 1 rendered block")
        guard case .toolGroup(let group) = blocks[0] else {
            return XCTFail("expected one toolGroup")
        }
        XCTAssertEqual(group.totalCount, 6)
    }
}
