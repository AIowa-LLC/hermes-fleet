import Foundation
import MetricKit
import os
import FleetCore

/// F0 — receives MetricKit daily metric payloads and diagnostic payloads and
/// keeps ONLY the aggregated numbers the diagnostics report needs.
///
/// Privacy boundary:
/// - Payloads stay on the device. Nothing here performs any network call.
/// - Only numbers are retained (medians, peaks, counts). Call-stack trees,
///   exception details, and every string in a payload are dropped.
/// - The summary lives in `FleetMetricKitSummaryStore` (in memory + one small
///   Caches file). It leaves the device only inside the existing
///   user-initiated Copy/Share of the redacted diagnostics report.
final class FleetMetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = FleetMetricKitSubscriber()

    private let manager: any FleetMetricManaging
    private let store: FleetMetricKitSummaryStore
    private let now: @Sendable () -> Date
    private let registered = OSAllocatedUnfairLock(initialState: false)

    init(
        manager: any FleetMetricManaging = SystemMetricManager(),
        store: FleetMetricKitSummaryStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager
        self.store = store
        self.now = now
        super.init()
    }

    /// Subscribe to MetricKit. Idempotent.
    func register() {
        let shouldAdd = registered.withLock { isRegistered -> Bool in
            if isRegistered { return false }
            isRegistered = true
            return true
        }
        if shouldAdd { manager.add(self) }
    }

    /// Unsubscribe. Idempotent; safe when never registered.
    func unregister() {
        let shouldRemove = registered.withLock { isRegistered -> Bool in
            if !isRegistered { return false }
            isRegistered = false
            return true
        }
        if shouldRemove { manager.remove(self) }
    }

    var isRegistered: Bool { registered.withLock { $0 } }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let summary = Self.metricsSummary(from: payloads, receivedAt: now()) else { return }
        store.record(metrics: summary)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let summary = Self.diagnosticsSummary(from: payloads, receivedAt: now()) else { return }
        store.record(diagnostics: summary)
    }

    // MARK: Aggregation (pure)

    /// Summarize the NEWEST metric payload (payloads are daily and ordered
    /// oldest-first). Nil for an empty batch.
    static func metricsSummary(
        from payloads: [MXMetricPayload], receivedAt: Date
    ) -> MetricKitMetricsSummary? {
        guard let payload = payloads.last else { return nil }
        return MetricKitMetricsSummary(
            receivedAt: receivedAt,
            foregroundSeconds: payload.applicationTimeMetrics?.cumulativeForegroundTime
                .converted(to: .seconds).value.sanitized,
            medianTimeToFirstDrawMilliseconds: payload.applicationLaunchMetrics
                .flatMap { medianMilliseconds($0.histogrammedTimeToFirstDraw) },
            medianResumeTimeMilliseconds: payload.applicationLaunchMetrics
                .flatMap { medianMilliseconds($0.histogrammedApplicationResumeTime) },
            medianHangTimeMilliseconds: payload.applicationResponsivenessMetrics
                .flatMap { medianMilliseconds($0.histogrammedApplicationHangTime) },
            peakMemoryMegabytes: payload.memoryMetrics?.peakMemoryUsage
                .converted(to: .megabytes).value.sanitized,
            logicalWritesMegabytes: payload.diskIOMetrics?.cumulativeLogicalWrites
                .converted(to: .megabytes).value.sanitized)
    }

    /// Count diagnostics across the whole batch. Nil for an empty batch.
    static func diagnosticsSummary(
        from payloads: [MXDiagnosticPayload], receivedAt: Date
    ) -> MetricKitDiagnosticsSummary? {
        guard !payloads.isEmpty else { return nil }
        return MetricKitDiagnosticsSummary(
            receivedAt: receivedAt,
            crashCount: payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) },
            hangCount: payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) },
            diskWriteExceptionCount: payloads.reduce(0) { $0 + ($1.diskWriteExceptionDiagnostics?.count ?? 0) },
            cpuExceptionCount: payloads.reduce(0) { $0 + ($1.cpuExceptionDiagnostics?.count ?? 0) })
    }

    private static func medianMilliseconds(_ histogram: MXHistogram<UnitDuration>) -> Double? {
        var buckets: [(start: Double, end: Double, count: Int)] = []
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            buckets.append((
                bucket.bucketStart.converted(to: .milliseconds).value,
                bucket.bucketEnd.converted(to: .milliseconds).value,
                bucket.bucketCount))
        }
        return histogramMedian(buckets)
    }

    /// Approximate median of a bucketed histogram: the midpoint of the bucket
    /// holding the middle observation. Nil when empty or non-finite.
    static func histogramMedian(_ buckets: [(start: Double, end: Double, count: Int)]) -> Double? {
        let ordered = buckets.filter { $0.count > 0 }.sorted { $0.start < $1.start }
        let total = ordered.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let target = Double(total) / 2
        var seen = 0
        for bucket in ordered {
            seen += bucket.count
            if Double(seen) >= target {
                return ((bucket.start + bucket.end) / 2).sanitized
            }
        }
        return nil
    }
}

private extension Double {
    /// Nil for NaN/infinite/negative so a malformed payload can never render.
    var sanitized: Double? { isFinite && self >= 0 ? self : nil }
}

/// The slice of `MXMetricManager` the subscriber needs, so registration can be
/// tested without touching the real MetricKit manager.
protocol FleetMetricManaging: Sendable {
    func add(_ subscriber: any MXMetricManagerSubscriber)
    func remove(_ subscriber: any MXMetricManagerSubscriber)
}

/// The real MetricKit manager behind the seam.
struct SystemMetricManager: FleetMetricManaging {
    func add(_ subscriber: any MXMetricManagerSubscriber) {
        MXMetricManager.shared.add(subscriber)
    }

    func remove(_ subscriber: any MXMetricManagerSubscriber) {
        MXMetricManager.shared.remove(subscriber)
    }
}

/// Starts `launch.to-paint` as the first property initializer of the app
/// struct, so the interval covers the rest of `App` initialization (including
/// building the service graph).
struct FleetLaunchSignpostMark {
    init(signposts: FleetSignposts = .shared) {
        signposts.beginLaunchToPaint()
    }
}
