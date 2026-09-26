import XCTest
import FleetCore

/// Card E — the pure lifecycle rules behind the image-generation animation.
///
/// Pins the honesty contract:
/// - only a verified `image_generate` frame starts the animation (never a
///   neighbouring tool's frame, never a prose-derived guess);
/// - the result, a failure, a cut-short turn, an interrupt and a transport
///   drop all end it;
/// - a replayed/re-delivered frame never resurrects a finished generation;
/// - the copy can never grow a fabricated percent/ETA/position.
final class ImageGenerationActivityTests: XCTestCase {

    private let session = "s-1"

    private func start(_ toolID: String = "t-img", name: String = "image_generate") -> ConversationEvent {
        .toolStart(sessionID: session, toolID: toolID, name: name, context: "draw a cat", argsText: nil)
    }

    private func complete(
        _ toolID: String = "t-img",
        name: String = "image_generate",
        result: String? = #"{"success": true, "image": "/home/u/.hermes/cache/images/cat.png"}"#
    ) -> ConversationEvent {
        .toolComplete(sessionID: session, toolID: toolID, name: name, summary: nil, resultText: result)
    }

    // MARK: - Verified starts

    func testToolStartNamingTheToolStartsGenerating() {
        let next = ImageGenerationRules.transition(current: nil, event: start())
        XCTAssertEqual(next, .generating(toolID: "t-img"))
        XCTAssertTrue(next?.isGenerating == true)
    }

    func testToolGeneratingStartsEvenBeforeToolStart() {
        // P0-8: tool.generating (no tool id) can arrive before tool.start.
        let next = ImageGenerationRules.transition(current: nil, event: .toolGenerating(sessionID: session, name: "image_generate"))
        XCTAssertEqual(next, .generating(toolID: nil))
    }

    func testToolGeneratingBeforeToolStartAdoptsTheToolID() {
        let first = ImageGenerationRules.transition(current: nil, event: .toolGenerating(sessionID: session, name: "image_generate"))
        let second = ImageGenerationRules.transition(current: first, event: start())
        XCTAssertEqual(second, .generating(toolID: "t-img"))
    }

    func testNamedProgressKeepsGenerating() {
        let next = ImageGenerationRules.transition(
            current: .generating(toolID: "t-img"),
            event: .toolProgress(sessionID: session, toolID: "t-img", name: "image_generate", text: "still working"))
        XCTAssertEqual(next, .generating(toolID: "t-img"))
    }

    func testFramesForOtherToolsNeverStartTheAnimation() {
        for event in [
            ConversationEvent.toolStart(sessionID: session, toolID: "t1", name: "web_search", context: "cats", argsText: nil),
            .toolGenerating(sessionID: session, name: "web_search"),
            .toolProgress(sessionID: session, toolID: "t1", name: "web_search", text: "3 results"),
            .toolComplete(sessionID: session, toolID: "t1", name: "web_search", summary: "3 results"),
        ] {
            XCTAssertNil(ImageGenerationRules.transition(current: nil, event: event),
                         "\(event) must not start the generation animation")
        }
    }

    func testAnonymousProgressNeverStartsTheAnimation() {
        // No name ⇒ no proof the frame belongs to a generation.
        let next = ImageGenerationRules.transition(
            current: nil,
            event: .toolProgress(sessionID: session, toolID: "t-img", name: nil, text: "50%"))
        XCTAssertNil(next)
    }

    // MARK: - Terminal frames

    func testToolCompleteDelivers() {
        let next = ImageGenerationRules.transition(current: .generating(toolID: "t-img"), event: complete())
        XCTAssertEqual(next, .delivered(toolID: "t-img"))
        XCTAssertTrue(next?.isTerminal == true)
    }

    func testExplicitFailureStopsWithFailed() {
        let next = ImageGenerationRules.transition(
            current: .generating(toolID: "t-img"),
            event: complete(result: #"{"success": false, "error": "boom"}"#))
        XCTAssertEqual(next, .stopped(toolID: "t-img", reason: .failed))
    }

    func testUnparseableResultIsNotAFailure() {
        // Desktop parity: only an explicit `success: false` is a failure.
        let next = ImageGenerationRules.transition(current: .generating(toolID: "t-img"), event: complete(result: "not json"))
        XCTAssertEqual(next, .delivered(toolID: "t-img"))
    }

    func testCompletionOfADifferentCallDoesNotEndThisOne() {
        let next = ImageGenerationRules.transition(current: .generating(toolID: "t-img-2"), event: complete("t-img-1"))
        XCTAssertNil(next)
    }

    func testTurnErrorStopsWithFailed() {
        let next = ImageGenerationRules.transition(
            current: .generating(toolID: "t-img"),
            event: .messageComplete(sessionID: session, text: "", status: "error", error: "provider down"))
        XCTAssertEqual(next, .stopped(toolID: "t-img", reason: .failed))
    }

    func testTurnSettlingWithoutTheResultStopsWithCancelled() {
        let next = ImageGenerationRules.transition(
            current: .generating(toolID: "t-img"),
            event: .messageComplete(sessionID: session, text: "done", status: nil, error: nil))
        XCTAssertEqual(next, .stopped(toolID: "t-img", reason: .cancelled))
    }

    func testTurnTerminalFramesAreNoOpsWithoutAnInFlightGeneration() {
        for current in [ImageGenerationActivity.delivered(toolID: "t-img"), .stopped(toolID: "t-img", reason: .failed)] {
            XCTAssertNil(ImageGenerationRules.transition(
                current: current,
                event: .messageComplete(sessionID: session, text: "", status: "error", error: "late")))
        }
        XCTAssertNil(ImageGenerationRules.transition(
            current: nil,
            event: .messageComplete(sessionID: session, text: "", status: nil, error: nil)))
    }

    func testErrorEventStopsWithFailed() {
        let next = ImageGenerationRules.transition(
            current: .generating(toolID: "t-img"),
            event: .error(sessionID: session, message: "stream died"))
        XCTAssertEqual(next, .stopped(toolID: "t-img", reason: .failed))
    }

    func testInterruptAndTransportStops() {
        XCTAssertEqual(
            ImageGenerationRules.stopped(.generating(toolID: "t-img"), reason: .cancelled),
            .stopped(toolID: "t-img", reason: .cancelled))
        XCTAssertEqual(
            ImageGenerationRules.stopped(.generating(toolID: "t-img"), reason: .disconnected),
            .stopped(toolID: "t-img", reason: .disconnected))
        XCTAssertNil(ImageGenerationRules.stopped(.delivered(toolID: "t-img"), reason: .cancelled))
        XCTAssertNil(ImageGenerationRules.stopped(nil, reason: .disconnected))
    }

    // MARK: - Replay safety

    func testReplayedStartNeverResurrectsAFinishedCall() {
        // Same tool id (or an id-less re-delivery): the finished call is not
        // restarted — this is what keeps a replayed frame from re-animating.
        for current in [
            ImageGenerationActivity.delivered(toolID: "t-img"),
            .stopped(toolID: "t-img", reason: .failed),
        ] {
            XCTAssertNil(ImageGenerationRules.transition(current: current, event: start()), "replayed tool.start")
            XCTAssertNil(ImageGenerationRules.transition(current: current, event: .toolGenerating(sessionID: session, name: "image_generate")),
                         "replayed tool.generating")
        }
    }

    func testANewCallOnTheSameRowRestartsTheAnimation() {
        // A second image_generate in one turn mints a NEW tool id; that is
        // proof of a new call and re-enters generating.
        let next = ImageGenerationRules.transition(
            current: .delivered(toolID: "t-img-1"),
            event: start("t-img-2"))
        XCTAssertEqual(next, .generating(toolID: "t-img-2"))
    }

    func testUnrelatedEventsAreNoOps() {
        let current = ImageGenerationActivity.generating(toolID: "t-img")
        for event in [
            ConversationEvent.messageDelta(sessionID: session, text: "hi", rendered: nil),
            .thinkingDelta(sessionID: session, text: "hmm"),
            .statusUpdate(sessionID: session, kind: "process", text: "working"),
            .usageUpdate(sessionID: session, usage: SessionUsageSnapshot(
                model: "m", input: 1, output: 1, total: 2, calls: 1,
                contextUsed: 1, contextMax: 2, contextPercent: 50)),
            .unknown(sessionID: session, rawType: "new.frame"),
        ] {
            XCTAssertNil(ImageGenerationRules.transition(current: current, event: event))
        }
    }

    // MARK: - Motion + copy honesty

    func testReduceMotionSelectsTheStillVariant() {
        XCTAssertEqual(ImageGenerationRules.motion(reduceMotion: true), .still)
        XCTAssertEqual(ImageGenerationRules.motion(reduceMotion: false), .animated)
    }

    func testCopyCarriesNoFabricatedProgress() {
        let copy = [
            ImageGenerationCopy.caption,
            ImageGenerationCopy.detail,
            ImageGenerationCopy.accessibilityLabel,
            ImageGenerationCopy.accessibilityValue,
        ]
        for line in copy {
            XCTAssertFalse(line.contains("%"), "no fabricated percentage in: \(line)")
            XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits), "no fabricated number in: \(line)")
            let lowered = line.lowercased()
            for word in ["eta", "remaining", "seconds", "percent", "estimate:"] {
                XCTAssertFalse(lowered.contains(word),
                               "'\(word)' implies a fabricated progress claim in: \(line)")
            }
        }
        // The honest statement of indeterminacy IS allowed (and tested).
        XCTAssertTrue(ImageGenerationCopy.detail.contains("no estimate"))
    }

    func testToolNameIsTheCardDCitationTool() {
        XCTAssertEqual(ImageGenerationRules.toolName, "image_generate")
        XCTAssertEqual(ImageGenerationRules.toolName, GeneratedImageRules.toolName)
    }
}
