import XCTest
import Foundation
@testable import FleetCore

/// F0 — signpost intervals begin/end exactly once, cancelled flows close with
/// a marker, and no caller identifier can reach a signpost.
final class FleetSignpostsTests: XCTestCase {
    private func makeSignposts() -> (FleetSignposts, FleetSignpostRecorder, FleetPerformanceStats) {
        let recorder = FleetSignpostRecorder()
        let stats = FleetPerformanceStats()
        return (FleetSignposts(sink: recorder, stats: stats), recorder, stats)
    }

    func testEachIntervalBeginsAndEndsExactlyOnce() {
        let (signposts, recorder, _) = makeSignposts()
        for interval in FleetSignpostInterval.allCases {
            let token = signposts.begin(interval)
            token.end()
            token.end(.failed) // a duplicate end must be ignored
        }
        for interval in FleetSignpostInterval.allCases {
            XCTAssertEqual(recorder.beginCount(interval), 1, "\(interval)")
            XCTAssertEqual(recorder.endEvents(interval).count, 1, "\(interval)")
            XCTAssertEqual(recorder.endEvents(interval).first?.outcome, .completed)
            XCTAssertTrue(recorder.isBalanced(interval))
        }
    }

    func testAbandonedIntervalClosesAsCancelledInsteadOfLeaking() {
        let (signposts, recorder, stats) = makeSignposts()
        do {
            _ = signposts.begin(.transcriptOpen)
        }
        XCTAssertEqual(recorder.endEvents(.transcriptOpen).count, 1)
        XCTAssertEqual(recorder.endEvents(.transcriptOpen).first?.outcome, .cancelled)
        XCTAssertTrue(recorder.isBalanced(.transcriptOpen))
        XCTAssertEqual(stats.samples(for: .transcriptOpen).first?.outcome, .cancelled)
    }

    func testErrorEndClassifiesCancellationAndFailure() {
        struct Boom: Error {}
        let (signposts, recorder, _) = makeSignposts()
        signposts.begin(.gatewayConnect).end(after: CancellationError())
        signposts.begin(.gatewayConnect).end(after: Boom())
        XCTAssertEqual(recorder.endEvents(.gatewayConnect).map(\.outcome), [.cancelled, .failed])
    }

    func testEndCarriesVariantAndCountMetadata() {
        let (signposts, recorder, _) = makeSignposts()
        signposts.begin(.replayPass).end(count: 7)
        signposts.begin(.transcriptOpen).end(variant: .cached)
        XCTAssertEqual(recorder.endEvents(.replayPass).first?.count, 7)
        XCTAssertEqual(recorder.endEvents(.transcriptOpen).first?.variant, .cached)
    }

    func testLaunchToPaintBeginsOnceEndsOnceAndIsNoOpWhenNeverBegun() {
        let (signposts, recorder, _) = makeSignposts()
        signposts.endLaunchToPaint(variant: .cached) // never begun: nothing
        XCTAssertTrue(recorder.events.isEmpty)

        signposts.beginLaunchToPaint()
        signposts.beginLaunchToPaint()
        signposts.endLaunchToPaint(variant: .cached, count: 3)
        signposts.endLaunchToPaint(variant: .live)
        XCTAssertEqual(recorder.beginCount(.launchToPaint), 1)
        XCTAssertEqual(recorder.endEvents(.launchToPaint).count, 1)
        XCTAssertEqual(recorder.endEvents(.launchToPaint).first?.variant, .cached)
        XCTAssertTrue(recorder.isBalanced(.launchToPaint))
    }

    func testConcurrentIntervalsGetDistinctNonIdentifyingIDs() {
        let (signposts, recorder, _) = makeSignposts()
        let first = signposts.begin(.gatewayConnect)
        let second = signposts.begin(.gatewayConnect)
        XCTAssertNotEqual(first.intervalID, second.intervalID)
        second.end()
        first.end()
        XCTAssertTrue(recorder.isBalanced(.gatewayConnect))
    }

    /// Identifiers cannot be passed in, so the assertion is over the complete
    /// rendered vocabulary: run every flow beside synthetic identifiers and
    /// prove none of them appear anywhere a trace could carry them.
    func testSignpostStringsNeverContainSyntheticIdentifiers() {
        let (signposts, recorder, _) = makeSignposts()
        let identifiers = [
            "gateway-alpha.internal.example", "sess_9f8e7d6c5b4a",
            "Quarterly payroll review", "Ledger Bot",
        ]

        signposts.beginLaunchToPaint()
        signposts.endLaunchToPaint(variant: .cached, count: 4)
        signposts.begin(.gatewayConnect).end()
        signposts.begin(.replayPass).end(count: 12)
        signposts.begin(.transcriptOpen).end(variant: .live)

        let rendered = recorder.renderedStrings.joined(separator: " ")
        for identifier in identifiers + ["internal", "example", "sess_"] {
            XCTAssertFalse(rendered.contains(identifier), "\(identifier) leaked: \(rendered)")
        }
        // The vocabulary is exactly the closed enums plus counts.
        let allowed = Set(["begin", "end"]
            + FleetSignpostInterval.allCases.map(\.rawValue)
            + ["completed", "failed", "cancelled", "cached", "live", "empty", "4", "12"])
        XCTAssertTrue(Set(recorder.renderedStrings).isSubset(of: allowed),
                      "unexpected signpost strings: \(recorder.renderedStrings)")
    }

    func testOSSignpostSinkEmitsWithoutTrapping() {
        // The OS sink is a thin shim over OSSignposter; exercise begin/end and
        // an end with no matching begin.
        let sink = FleetOSSignpostSink()
        let signposts = FleetSignposts(sink: sink)
        signposts.begin(.gatewayConnect).end()
        signposts.begin(.replayPass).end(.failed, count: 2)
        sink.emit(FleetSignpostEvent(phase: .end, interval: .replayPass, intervalID: 9_999))
    }
}
