import XCTest
import Foundation
@testable import FleetCore

/// F0 — bounded interval stats, the MetricKit summary store, and the
/// PERFORMANCE section of the diagnostics report.
final class FleetPerformanceStatsTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ interval: FleetSignpostInterval, ms: Double,
                        outcome: FleetSignpostOutcome = .completed) -> FleetPerformanceSample {
        FleetPerformanceSample(interval: interval, outcome: outcome, variant: nil,
                               count: nil, durationMilliseconds: ms)
    }

    func testSummaryMinMedianMaxOverCompletedSamplesOnly() {
        let stats = FleetPerformanceStats()
        for ms in [300.0, 100.0, 200.0, 400.0] { stats.record(sample(.launchToPaint, ms: ms)) }
        stats.record(sample(.launchToPaint, ms: 9_999, outcome: .cancelled))
        stats.record(sample(.launchToPaint, ms: 9_999, outcome: .failed))
        let summary = stats.summaries().first { $0.interval == .launchToPaint }
        XCTAssertEqual(summary?.completedCount, 4)
        XCTAssertEqual(summary?.minMilliseconds, 100)
        XCTAssertEqual(summary?.medianMilliseconds, 250)
        XCTAssertEqual(summary?.maxMilliseconds, 400)
        XCTAssertEqual(summary?.failedCount, 1)
        XCTAssertEqual(summary?.cancelledCount, 1)
    }

    func testRingIsBoundedAndKeepsNewest() {
        let stats = FleetPerformanceStats(sampleLimit: 3)
        for ms in 1...10 { stats.record(sample(.replayPass, ms: Double(ms))) }
        XCTAssertEqual(stats.samples(for: .replayPass).map(\.durationMilliseconds), [8, 9, 10])
    }

    func testSummariesCoverEveryIntervalEvenWhenEmpty() {
        XCTAssertEqual(FleetPerformanceStats().summaries().map(\.interval),
                       FleetSignpostInterval.allCases)
    }

    // MARK: MetricKit store

    func testMetricKitStoreStartsEmpty() {
        XCTAssertTrue(FleetMetricKitSummaryStore(fileURL: nil).latest().isEmpty)
    }

    func testMetricKitStorePersistsReloadsAndClears() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-f0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("summary.json")

        let store = FleetMetricKitSummaryStore(fileURL: url)
        store.record(metrics: MetricKitMetricsSummary(
            receivedAt: fixedNow, medianTimeToFirstDrawMilliseconds: 380, peakMemoryMegabytes: 120))
        store.record(diagnostics: MetricKitDiagnosticsSummary(
            receivedAt: fixedNow, crashCount: 1, hangCount: 2))

        let reloaded = FleetMetricKitSummaryStore(fileURL: url).latest()
        XCTAssertEqual(reloaded.metrics?.medianTimeToFirstDrawMilliseconds, 380)
        XCTAssertEqual(reloaded.diagnostics?.hangCount, 2)

        store.clear()
        XCTAssertTrue(store.latest().isEmpty)
        XCTAssertTrue(FleetMetricKitSummaryStore(fileURL: url).latest().isEmpty)
    }

    func testCorruptSummaryFileIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-f0-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(FleetMetricKitSummaryStore(fileURL: url).latest().isEmpty)
    }

    // MARK: Report golden

    private func input(performance: FleetPerformanceReport?) -> DiagnosticsReportInput {
        DiagnosticsReportInput(
            generatedAt: fixedNow, reportID: "DF-231114-221320-A1B2", appVersion: "0.2.0",
            appBuild: "83", osVersion: "26.0", deviceModel: "iPhone17,2",
            performance: performance)
    }

    func testReportPerformanceSectionGolden() {
        let intervals: [FleetIntervalSummary] = [
            FleetIntervalSummary(interval: .launchToPaint, completedCount: 3, failedCount: 0,
                                 cancelledCount: 0, minMilliseconds: 210, medianMilliseconds: 240,
                                 maxMilliseconds: 380),
            FleetIntervalSummary(interval: .gatewayConnect, completedCount: 2, failedCount: 1,
                                 cancelledCount: 1, minMilliseconds: 500, medianMilliseconds: 650,
                                 maxMilliseconds: 800),
            FleetIntervalSummary(interval: .replayPass, completedCount: 0, failedCount: 0,
                                 cancelledCount: 0, minMilliseconds: nil, medianMilliseconds: nil,
                                 maxMilliseconds: nil),
            FleetIntervalSummary(interval: .transcriptOpen, completedCount: 1, failedCount: 0,
                                 cancelledCount: 0, minMilliseconds: 90, medianMilliseconds: 90,
                                 maxMilliseconds: 90),
        ]
        let kit = MetricKitSummary(
            metrics: MetricKitMetricsSummary(
                receivedAt: fixedNow, foregroundSeconds: 3600,
                medianTimeToFirstDrawMilliseconds: 375, peakMemoryMegabytes: 142),
            diagnostics: MetricKitDiagnosticsSummary(
                receivedAt: fixedNow, crashCount: 0, hangCount: 2,
                diskWriteExceptionCount: 0, cpuExceptionCount: 1))
        let text = DiagnosticsReport.render(input(
            performance: FleetPerformanceReport(intervals: intervals, metricKit: kit)))

        let expected = """
        PERFORMANCE
          launch.to-paint: n=3 min 210 ms / median 240 ms / max 380 ms
          gateway.connect: n=2 min 500 ms / median 650 ms / max 800 ms (1 failed, 1 cancelled)
          replay.pass: no completed samples
          transcript.open: n=1 min 90 ms / median 90 ms / max 90 ms
          MetricKit metrics (received 2023-11-14T22:13:20Z):
            Foreground time: 3600 s
            Launch to first draw (median): 375 ms
            Peak memory: 142 MB
          MetricKit diagnostics (received 2023-11-14T22:13:20Z):
            Crashes: 0
            Hangs: 2
            Disk-write exceptions: 0
            CPU exceptions: 1

        GATEWAYS
        """
        XCTAssertTrue(text.contains(expected), "golden mismatch:\n\(text)")
    }

    func testReportPerformanceHonestAbsence() {
        XCTAssertTrue(DiagnosticsReport.render(input(performance: nil))
            .contains("PERFORMANCE\n  no performance data supplied\n"))
        let empty = DiagnosticsReport.render(input(performance: FleetPerformanceReport(
            intervals: FleetPerformanceStats().summaries())))
        XCTAssertTrue(empty.contains("  launch.to-paint: no completed samples"))
        XCTAssertTrue(empty.contains("  MetricKit: none received yet"))
    }

    func testReportWithPerformanceIsFreeOfSecretsAndOmitsBadNumbers() {
        let stats = FleetPerformanceStats()
        stats.record(sample(.gatewayConnect, ms: 12))
        let text = DiagnosticsReport.render(input(performance: FleetPerformanceReport(
            intervals: stats.summaries(),
            metricKit: MetricKitSummary(metrics: MetricKitMetricsSummary(
                receivedAt: fixedNow, medianHangTimeMilliseconds: .nan, peakMemoryMegabytes: -5)))))
        for marker in ["://", "ticket=", "token=", "ENDPOINT REDACTED"] {
            XCTAssertFalse(text.contains(marker), "\(marker) must not appear: \(text)")
        }
        XCTAssertFalse(text.contains("Hang time"), "non-finite metrics must be omitted: \(text)")
        XCTAssertFalse(text.contains("Peak memory"), "negative metrics must be omitted: \(text)")
    }
}
