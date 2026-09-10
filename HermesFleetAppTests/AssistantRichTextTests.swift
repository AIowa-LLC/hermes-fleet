import SwiftUI
import XCTest
@testable import FleetUI

/// Issue #5 deterministic presentation tests. These deliberately observe the
/// Fleet-owned policy/source boundary instead of snapshotting dependency
/// internals: the Markdown renderer is free to change its private view tree,
/// while Fleet's role, safety, lifecycle, and configuration contracts remain
/// stable.
@MainActor
final class AssistantRichTextTests: XCTestCase {

    func testMarkdownFixtureCoversRequiredSyntaxAndSafetyProjection() {
        let fixture = """
        # Heading one
        ## Heading two
        ### Heading three

        A paragraph with **bold**, *italic*, ~~strikethrough~~, and `inline code`.

        ```swift
        let answer = "streaming"
        ```

        - unordered item
        - [x] completed task
        1. ordered item
        2. second item

        > A blockquote from the assistant.

        [safe link](https://example.com/docs)

        | Name | State |
        | --- | --- |
        | parser | active |

        ---

        <script>alert("inert")</script>
        ![pixel](https://example.invalid/tracker.png)
        [unsafe](javascript:alert(1))
        [local](file:///tmp/private.txt)
        [custom](myapp://private)
        [relative](docs/readme)
        [malformed](not a valid destination)
        Malformed **bold and [link
        """

        let sanitized = AssistantRichTextMarkdownSafety.sanitizedMarkdown(fixture)

        // The display projection preserves Markdown content and the safe link.
        for marker in [
            "# Heading one", "## Heading two", "### Heading three", "**bold**",
            "*italic*", "~~strikethrough~~", "`inline code`", "```swift",
            "- [x] completed task", "1. ordered item", "> A blockquote",
            "[safe link](https://example.com/docs)", "| parser | active |", "---",
            "<script>alert(\"inert\")</script>",
            "![pixel](https://example.invalid/tracker.png)",
        ] {
            XCTAssertTrue(sanitized.contains(marker), "fixture marker disappeared: \(marker)")
        }

        // Unsafe destinations become visible, non-interactive labels. No
        // unsafe scheme reaches the third-party renderer input.
        for unsafe in ["javascript:", "file:", "myapp://", "docs/readme", "not a valid destination"] {
            XCTAssertFalse(sanitized.contains(unsafe), "unsafe destination leaked: \(unsafe)")
        }
        XCTAssertTrue(sanitized.contains("unsafe"))
        XCTAssertTrue(sanitized.contains("local"))
        XCTAssertTrue(sanitized.contains("custom"))
        XCTAssertTrue(sanitized.contains("relative"))
        XCTAssertTrue(sanitized.contains("malformed"))
    }

    func testRoleSelectionKeepsUserAndNonMessageRowsLiteral() {
        XCTAssertTrue(AssistantRichTextPresentation.shouldRenderDirect(.assistant))
        for kind in [ConversationRow.Kind.user, .tool, .status, .system, .error] {
            XCTAssertFalse(
                AssistantRichTextPresentation.shouldRenderDirect(kind),
                "only direct assistant rows may use rich Markdown")
        }

        XCTAssertTrue(AssistantRichTextPresentation.shouldRenderRoom(.message(isUser: false)))
        XCTAssertFalse(AssistantRichTextPresentation.shouldRenderRoom(.message(isUser: true)))
        XCTAssertFalse(AssistantRichTextPresentation.shouldRenderRoom(.failure))
    }

    func testURLPolicyRequiresExplicitSafeHTTPSDestination() {
        XCTAssertTrue(AssistantRichTextURLPolicy.isActionable(URL(string: "https://example.com/docs")!))
        XCTAssertFalse(AssistantRichTextURLPolicy.isActionable(URL(string: "http://example.com/docs")!))
        XCTAssertFalse(AssistantRichTextURLPolicy.isActionable(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(AssistantRichTextURLPolicy.isActionable(URL(string: "file:///tmp/private.txt")!))
        XCTAssertFalse(AssistantRichTextURLPolicy.isActionable(URL(string: "myapp://private")!))
        XCTAssertFalse(AssistantRichTextURLPolicy.isActionable(URL(string: "https://user:password@example.com")!))
        XCTAssertFalse(AssistantRichTextURLPolicy.isActionable(URL(string: "https:///missing-host")!))
    }

    func testRendererConfigurationDisablesImagesAndRevealAnimation() {
        let normal = FleetMarkdownRenderConfiguration.make(
            reduceMotion: false,
            dynamicTypeSize: .large)
        let reduced = FleetMarkdownRenderConfiguration.make(
            reduceMotion: true,
            dynamicTypeSize: .accessibility3)

        XCTAssertFalse(normal.imageConfig.enabled, "remote image loading must be off in V1")
        XCTAssertFalse(reduced.imageConfig.enabled, "remote image loading must be off in V1")
        XCTAssertFalse(normal.shouldAnimateText, "streaming text must not reveal/flicker per token")
        XCTAssertFalse(reduced.shouldAnimateText, "Reduce Motion must remain a hard no-animation path")
    }

    func testStreamingSourceCarriesFullSnapshotsWithoutRecreatingIdentity() async {
        let snapshots = [
            "**bo",
            "**bold** and *ita",
            "**bold** and *italic*\n\n- parti",
            "**bold** and *italic*\n\n- partial list\n\n```swift\nlet value =",
            "**bold** and *italic*\n\n- partial list\n\n```swift\nlet value = 1\n```\n\n| Name | State |\n| --- | --- |\n| parser | active |",
        ]
        let source = AssistantRichTextStreamSource(
            identity: "row-42",
            snapshot: snapshots[0],
            isStreaming: true)
        let stableObject = ObjectIdentifier(source)
        var iterator = source.text.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, snapshots[0])
        for snapshot in snapshots.dropFirst() {
            source.publish(snapshot)
            let received = await iterator.next()
            XCTAssertEqual(received, snapshot)
            XCTAssertEqual(ObjectIdentifier(source), stableObject)
        }

        // A repeated full snapshot is ignored rather than appended, so the
        // renderer cannot duplicate the current answer.
        let updateCount = source.snapshotUpdateCount
        source.publish(snapshots.last!)
        XCTAssertEqual(source.snapshotUpdateCount, updateCount)
        XCTAssertEqual(source.latestSnapshot, snapshots.last)

        source.finish()
        XCTAssertTrue(source.isFinished)
        let afterFinish = await iterator.next()
        XCTAssertNil(afterFinish)
    }

    func testCompletedLiveAndHistorySourcesConvergeToTheSameMarkdown() {
        let finalMarkdown = """
        # Final answer

        This has **bold** text and an incomplete-looking `code` span.

        ```swift
        let ready = true
        ```
        """
        let live = AssistantRichTextStreamSource(
            identity: "live-row",
            snapshot: "# Final answer\n\nThis has **bold",
            isStreaming: true)
        live.publish(finalMarkdown)
        live.finish()

        let history = AssistantRichTextStreamSource(
            identity: "history-row",
            snapshot: finalMarkdown,
            isStreaming: false)

        XCTAssertEqual(live.latestSnapshot, history.latestSnapshot)
        XCTAssertTrue(history.isFinished)
    }

    func testStressFixtureIsBoundedAndSupportsManyIncrementalSnapshots() {
        let block = """
        ## Repeated answer section
        Prose stays compact while **emphasis**, *context*, and `inline code` remain readable.
        - [ ] queued item
        - [x] completed item
        1. ordered item
        > quoted context
        ```swift
        let value = "mixed prose, code, lists, and tables"
        ```
        | Column | Value |
        | --- | --- |
        | state | streaming |

        """
        let stressMarkdown = String(repeating: block, count: 23)
        XCTAssertGreaterThanOrEqual(stressMarkdown.utf8.count, 5_000)
        XCTAssertLessThanOrEqual(stressMarkdown.utf8.count, 10_000)

        let source = AssistantRichTextStreamSource(
            identity: "stress-row",
            snapshot: "",
            isStreaming: true)
        let step = max(1, stressMarkdown.count / 240)
        var snapshotCount = 0
        for offset in stride(from: step, through: stressMarkdown.count, by: step) {
            source.publish(String(stressMarkdown.prefix(offset)))
            snapshotCount += 1
        }
        if source.latestSnapshot != stressMarkdown {
            source.publish(stressMarkdown)
            snapshotCount += 1
        }
        source.finish()

        XCTAssertGreaterThanOrEqual(snapshotCount, 200)
        XCTAssertEqual(source.latestSnapshot, stressMarkdown)
        XCTAssertEqual(source.snapshotUpdateCount, snapshotCount)
        XCTAssertTrue(source.isFinished)

        // Cold-cache/history projection uses fresh disposable sources but the
        // exact same final Markdown snapshot. Keep a substantial completed
        // history fixture in the deterministic test without persisting any
        // renderer state.
        let completedHistory = (0..<24).map { index in
            AssistantRichTextStreamSource(
                identity: "history-\(index)",
                snapshot: stressMarkdown,
                isStreaming: false)
        }
        XCTAssertEqual(completedHistory.count, 24)
        XCTAssertTrue(completedHistory.allSatisfy { $0.isFinished && $0.latestSnapshot == stressMarkdown })
    }
}
