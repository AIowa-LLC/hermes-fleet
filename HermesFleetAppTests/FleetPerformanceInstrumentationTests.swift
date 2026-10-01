import XCTest
import MetricKit
@testable import FleetCore
@testable import HermesFleetApp

/// F0 hosted units: the MetricKit subscriber (on-device aggregation only).
/// The interval wiring is covered in `AppEnvironmentTests` (launch.to-paint)
/// and `ConversationViewModelTests` (transcript.open).
@MainActor
final class FleetPerformanceInstrumentationTests: XCTestCase {

    // MARK: MetricKit subscriber

    private final class FakeMetricManager: FleetMetricManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _added = 0
        private var _removed = 0
        var added: Int { lock.lock(); defer { lock.unlock() }; return _added }
        var removed: Int { lock.lock(); defer { lock.unlock() }; return _removed }
        func add(_ subscriber: any MXMetricManagerSubscriber) { lock.lock(); _added += 1; lock.unlock() }
        func remove(_ subscriber: any MXMetricManagerSubscriber) { lock.lock(); _removed += 1; lock.unlock() }
    }

    func testSubscriberRegistersAndUnregistersCleanlyAndIdempotently() {
        let manager = FakeMetricManager()
        let subscriber = FleetMetricKitSubscriber(
            manager: manager, store: FleetMetricKitSummaryStore(fileURL: nil))

        subscriber.unregister() // never registered: no-op
        XCTAssertEqual(manager.removed, 0)

        subscriber.register()
        subscriber.register()
        XCTAssertEqual(manager.added, 1)
        XCTAssertTrue(subscriber.isRegistered)

        subscriber.unregister()
        subscriber.unregister()
        XCTAssertEqual(manager.removed, 1)
        XCTAssertFalse(subscriber.isRegistered)
    }

    func testEmptyPayloadBatchesAreIgnored() {
        let store = FleetMetricKitSummaryStore(fileURL: nil)
        let subscriber = FleetMetricKitSubscriber(manager: FakeMetricManager(), store: store)
        subscriber.didReceive([MXMetricPayload]())
        subscriber.didReceive([MXDiagnosticPayload]())
        XCTAssertTrue(store.latest().isEmpty)
    }

    func testPayloadWithNoMetricsRecordsAnEmptyButSafeSummary() {
        let store = FleetMetricKitSummaryStore(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let subscriber = FleetMetricKitSubscriber(
            manager: FakeMetricManager(), store: store, now: { now })
        subscriber.didReceive([MXMetricPayload()])
        subscriber.didReceive([MXDiagnosticPayload()])

        let latest = store.latest()
        XCTAssertEqual(latest.metrics?.receivedAt, now)
        XCTAssertNil(latest.metrics?.medianTimeToFirstDrawMilliseconds)
        XCTAssertNil(latest.metrics?.peakMemoryMegabytes)
        XCTAssertEqual(latest.diagnostics?.crashCount, 0)
        XCTAssertEqual(latest.diagnostics?.hangCount, 0)
    }

    func testHistogramMedianUsesMiddleBucketMidpoint() {
        XCTAssertNil(FleetMetricKitSubscriber.histogramMedian([]))
        XCTAssertNil(FleetMetricKitSubscriber.histogramMedian([(start: 0, end: 10, count: 0)]))
        let median = FleetMetricKitSubscriber.histogramMedian([
            (start: 200, end: 300, count: 1),
            (start: 0, end: 100, count: 5),
            (start: 100, end: 200, count: 4),
        ])
        XCTAssertEqual(median, 50) // 10 observations: the 5th falls in the first bucket
        XCTAssertEqual(FleetMetricKitSubscriber.histogramMedian([
            (start: 0, end: 100, count: 1), (start: 100, end: 200, count: 3),
        ]), 150)
    }
}
