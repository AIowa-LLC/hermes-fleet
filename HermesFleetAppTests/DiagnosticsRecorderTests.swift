import XCTest
import FleetCore
@testable import FleetUI

/// P0-A — the bounded frame/roster/connection-fault ring the "Report a
/// Problem" diagnostics report renders.
///
/// Three contracts, each of which a naive implementation gets wrong:
/// - the ring is CAPPED (a long session cannot grow it without end),
/// - `snapshot()` is OLDEST-FIRST with the NEWEST kept,
/// - and the detail is REDACTED at record time (a secret must not even sit in
///   memory, let alone reach a shareable report).
@MainActor
final class DiagnosticsRecorderTests: XCTestCase {

    // MARK: - Cap

    func testRingIsCappedAtLimitAndKeepsTheNewest() {
        let recorder = DiagnosticsRecorder(limit: 3)
        for index in 0..<5 {
            recorder.record(category: "Cat \(index)", detail: "detail \(index)")
        }
        let entries = recorder.snapshot()
        XCTAssertEqual(entries.count, 3, "the ring must not exceed its limit")
        XCTAssertEqual(entries.map(\.detail), ["detail 2", "detail 3", "detail 4"],
                       "the newest entries are kept and the oldest evicted")
    }

    func testDefaultLimitIsThirty() {
        let recorder = DiagnosticsRecorder()
        XCTAssertEqual(recorder.limit, 30)
        for index in 0..<35 {
            recorder.record(category: "Cat", detail: "detail \(index)")
        }
        let entries = recorder.snapshot()
        XCTAssertEqual(entries.count, 30)
        XCTAssertEqual(entries.first?.detail, "detail 5", "the first five were evicted")
        XCTAssertEqual(entries.last?.detail, "detail 34")
    }

    func testLimitIsClampedToAtLeastOne() {
        XCTAssertEqual(DiagnosticsRecorder(limit: 0).limit, 1)
        XCTAssertEqual(DiagnosticsRecorder(limit: -7).limit, 1)

        let recorder = DiagnosticsRecorder(limit: 0)
        recorder.record(category: "Cat", detail: "first")
        recorder.record(category: "Cat", detail: "second")
        XCTAssertEqual(recorder.snapshot().map(\.detail), ["second"])
    }

    // MARK: - Ordering

    func testSnapshotIsOldestFirst() {
        let recorder = DiagnosticsRecorder(limit: 10)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Recorded newest-first on purpose: insertion order is the contract.
        recorder.record(category: "Third", detail: "c", at: base.addingTimeInterval(2))
        recorder.record(category: "First", detail: "a", at: base)
        recorder.record(category: "Second", detail: "b", at: base.addingTimeInterval(1))
        let entries = recorder.snapshot()
        XCTAssertEqual(entries.map(\.detail), ["c", "a", "b"],
                       "snapshot preserves insertion order (oldest-first)")
        XCTAssertEqual(entries.map(\.category), ["Third", "First", "Second"])
        XCTAssertEqual(entries.map(\.at), [
            base.addingTimeInterval(2), base, base.addingTimeInterval(1),
        ], "each entry keeps the timestamp it was recorded with")
    }

    func testClearDropsEveryEntry() {
        let recorder = DiagnosticsRecorder(limit: 5)
        recorder.record(category: "Gateway connection", detail: "offline")
        recorder.record(category: "Roster refresh", detail: "timed out")
        XCTAssertEqual(recorder.snapshot().count, 2)
        recorder.clear()
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    // MARK: - Redaction at record time

    func testRecordRedactsCredentialShapedDetail() {
        let recorder = DiagnosticsRecorder(limit: 5)
        recorder.record(
            category: "Gateway connection",
            detail: "Couldn't reach MacBook at https://user:pass@host/?ticket=SECRETVALUE — token=abc12345")

        guard let entry = recorder.snapshot().first else {
            return XCTFail("expected one recorded entry")
        }
        for secret in ["abc12345", "SECRETVALUE", "user:pass@"] {
            XCTAssertFalse(entry.detail.contains(secret),
                           "\(secret) must be redacted before it is stored: \(entry.detail)")
        }
        XCTAssertTrue(entry.detail.contains(Redaction.placeholder), entry.detail)
        XCTAssertTrue(entry.detail.contains("[REDACTED]host/?ticket=[REDACTED]"), entry.detail)
    }

    func testRecordRedactsCredentialShapedCategoryToo() {
        let recorder = DiagnosticsRecorder(limit: 5)
        recorder.record(category: "Auth token=abc12345", detail: "rejected")
        guard let entry = recorder.snapshot().first else {
            return XCTFail("expected one recorded entry")
        }
        XCTAssertFalse(entry.category.contains("abc12345"), entry.category)
        XCTAssertTrue(entry.category.contains("token=[REDACTED]"), entry.category)
    }

    func testRecordedDetailIsSafeToRenderInTheReport() {
        let recorder = DiagnosticsRecorder(limit: 5)
        recorder.record(category: "Gateway connection", detail: "token=abc12345")
        let events = recorder.snapshot().map {
            DiagnosticsEvent(at: $0.at, category: $0.category, detail: $0.detail)
        }
        let report = DiagnosticsReport.render(DiagnosticsReportInput(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reportID: "DF-231114-221320-A1B2",
            appVersion: "0.2.0",
            appBuild: "83",
            osVersion: "26.0",
            deviceModel: "iPhone17,2",
            gateways: [],
            recentEvents: events))
        XCTAssertTrue(report.contains("No gateways configured."), report)
        XCTAssertFalse(report.contains("abc12345"), report)
    }
}