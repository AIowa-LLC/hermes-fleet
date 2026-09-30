import Foundation
import os

// F0 — bounded, in-memory interval timings and the latest MetricKit summary,
// as rendered by the diagnostics report's PERFORMANCE section.
//
// Everything here is numbers and closed-vocabulary labels: no hostnames,
// session ids, titles, or bot names can be stored, so nothing needs
// redacting — and the renderer still passes every string through
// `Redaction.safeDiagnosticReportText` as the last line of defense.

/// One recorded interval outcome (in memory only).
public struct FleetPerformanceSample: Sendable, Equatable {
    public let interval: FleetSignpostInterval
    public let outcome: FleetSignpostOutcome
    public let variant: FleetSignpostVariant?
    public let count: Int?
    /// Wall-clock duration in milliseconds.
    public let durationMilliseconds: Double

    public init(interval: FleetSignpostInterval, outcome: FleetSignpostOutcome,
                variant: FleetSignpostVariant?, count: Int?, durationMilliseconds: Double) {
        self.interval = interval
        self.outcome = outcome
        self.variant = variant
        self.count = count
        self.durationMilliseconds = durationMilliseconds
    }
}

/// min/median/max over the retained completed samples of one interval.
public struct FleetIntervalSummary: Sendable, Equatable {
    public let interval: FleetSignpostInterval
    /// Completed samples the statistics cover.
    public let completedCount: Int
    public let failedCount: Int
    public let cancelledCount: Int
    public let minMilliseconds: Double?
    public let medianMilliseconds: Double?
    public let maxMilliseconds: Double?

    public init(interval: FleetSignpostInterval, completedCount: Int, failedCount: Int,
                cancelledCount: Int, minMilliseconds: Double?, medianMilliseconds: Double?,
                maxMilliseconds: Double?) {
        self.interval = interval
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.minMilliseconds = minMilliseconds
        self.medianMilliseconds = medianMilliseconds
        self.maxMilliseconds = maxMilliseconds
    }
}

/// Bounded ring of the most recent samples per interval.
public final class FleetPerformanceStats: Sendable {
    public static let shared = FleetPerformanceStats()

    /// Maximum retained samples per interval (oldest evicted).
    public let sampleLimit: Int
    private let storage = OSAllocatedUnfairLock<[FleetSignpostInterval: [FleetPerformanceSample]]>(
        initialState: [:])

    public init(sampleLimit: Int = 20) {
        self.sampleLimit = max(1, sampleLimit)
    }

    public func record(interval: FleetSignpostInterval, outcome: FleetSignpostOutcome,
                       variant: FleetSignpostVariant?, count: Int?, duration: Duration) {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        record(FleetPerformanceSample(
            interval: interval, outcome: outcome, variant: variant, count: count,
            durationMilliseconds: max(0, milliseconds)))
    }

    public func record(_ sample: FleetPerformanceSample) {
        let limit = sampleLimit
        storage.withLock { all in
            var samples = all[sample.interval, default: []]
            samples.append(sample)
            if samples.count > limit { samples.removeFirst(samples.count - limit) }
            all[sample.interval] = samples
        }
    }

    /// Samples for one interval, oldest-first.
    public func samples(for interval: FleetSignpostInterval) -> [FleetPerformanceSample] {
        storage.withLock { $0[interval] ?? [] }
    }

    /// One summary per interval, in the enum's stable order.
    public func summaries() -> [FleetIntervalSummary] {
        let all = storage.withLock { $0 }
        return FleetSignpostInterval.allCases.map { interval in
            let samples = all[interval] ?? []
            let completed = samples.filter { $0.outcome == .completed }
                .map(\.durationMilliseconds).sorted()
            return FleetIntervalSummary(
                interval: interval,
                completedCount: completed.count,
                failedCount: samples.filter { $0.outcome == .failed }.count,
                cancelledCount: samples.filter { $0.outcome == .cancelled }.count,
                minMilliseconds: completed.first,
                medianMilliseconds: Self.median(of: completed),
                maxMilliseconds: completed.last)
        }
    }

    public func clear() {
        storage.withLock { $0.removeAll() }
    }

    static func median(of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

// MARK: - MetricKit summary

/// Aggregated numbers from the latest MetricKit daily metric payload. Numbers
/// only (no call stacks, no strings); every field is optional because
/// MetricKit omits metrics it did not collect.
public struct MetricKitMetricsSummary: Sendable, Equatable, Codable {
    public var receivedAt: Date
    public var foregroundSeconds: Double?
    public var medianTimeToFirstDrawMilliseconds: Double?
    public var medianResumeTimeMilliseconds: Double?
    public var medianHangTimeMilliseconds: Double?
    public var peakMemoryMegabytes: Double?
    public var logicalWritesMegabytes: Double?

    public init(receivedAt: Date, foregroundSeconds: Double? = nil,
                medianTimeToFirstDrawMilliseconds: Double? = nil,
                medianResumeTimeMilliseconds: Double? = nil,
                medianHangTimeMilliseconds: Double? = nil,
                peakMemoryMegabytes: Double? = nil,
                logicalWritesMegabytes: Double? = nil) {
        self.receivedAt = receivedAt
        self.foregroundSeconds = foregroundSeconds
        self.medianTimeToFirstDrawMilliseconds = medianTimeToFirstDrawMilliseconds
        self.medianResumeTimeMilliseconds = medianResumeTimeMilliseconds
        self.medianHangTimeMilliseconds = medianHangTimeMilliseconds
        self.peakMemoryMegabytes = peakMemoryMegabytes
        self.logicalWritesMegabytes = logicalWritesMegabytes
    }
}

/// Counts from the latest MetricKit diagnostic payload batch.
public struct MetricKitDiagnosticsSummary: Sendable, Equatable, Codable {
    public var receivedAt: Date
    public var crashCount: Int
    public var hangCount: Int
    public var diskWriteExceptionCount: Int
    public var cpuExceptionCount: Int

    public init(receivedAt: Date, crashCount: Int = 0, hangCount: Int = 0,
                diskWriteExceptionCount: Int = 0, cpuExceptionCount: Int = 0) {
        self.receivedAt = receivedAt
        self.crashCount = crashCount
        self.hangCount = hangCount
        self.diskWriteExceptionCount = diskWriteExceptionCount
        self.cpuExceptionCount = cpuExceptionCount
    }
}

/// The latest MetricKit summary (either half may be absent).
public struct MetricKitSummary: Sendable, Equatable, Codable {
    public var metrics: MetricKitMetricsSummary?
    public var diagnostics: MetricKitDiagnosticsSummary?

    public init(metrics: MetricKitMetricsSummary? = nil,
                diagnostics: MetricKitDiagnosticsSummary? = nil) {
        self.metrics = metrics
        self.diagnostics = diagnostics
    }

    public var isEmpty: Bool { metrics == nil && diagnostics == nil }
}

/// Holds the latest MetricKit summary: in memory, mirrored to one small
/// file when given a URL (MetricKit delivers a daily payload at most once per
/// day, so a report opened in a later launch would otherwise be empty).
/// On-device only — nothing here performs any network call.
public final class FleetMetricKitSummaryStore: Sendable {
    public static let shared = FleetMetricKitSummaryStore(fileURL: defaultFileURL())

    private let fileURL: URL?
    private let state: OSAllocatedUnfairLock<MetricKitSummary>

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        var initial = MetricKitSummary()
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(MetricKitSummary.self, from: data) {
            initial = decoded
        }
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    /// `Caches/FleetPerformance/metrickit-summary.json` (purgeable by the OS,
    /// never backed up), or nil when no caches directory is available.
    public static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FleetPerformance", isDirectory: true)
            .appendingPathComponent("metrickit-summary.json")
    }

    public func latest() -> MetricKitSummary { state.withLock { $0 } }

    public func record(metrics: MetricKitMetricsSummary) {
        update { $0.metrics = metrics }
    }

    public func record(diagnostics: MetricKitDiagnosticsSummary) {
        update { $0.diagnostics = diagnostics }
    }

    /// Forget the stored summary (memory and file).
    public func clear() {
        state.withLock { $0 = MetricKitSummary() }
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func update(_ change: @Sendable (inout MetricKitSummary) -> Void) {
        let snapshot = state.withLock { summary -> MetricKitSummary in
            change(&summary)
            return summary
        }
        persist(snapshot)
    }

    private func persist(_ summary: MetricKitSummary) {
        guard let fileURL, let data = try? JSONEncoder().encode(summary) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try? data.write(to: fileURL, options: options)
    }
}

/// What the diagnostics report renders in its PERFORMANCE section.
public struct FleetPerformanceReport: Sendable, Equatable {
    public let intervals: [FleetIntervalSummary]
    public let metricKit: MetricKitSummary

    public init(intervals: [FleetIntervalSummary], metricKit: MetricKitSummary = MetricKitSummary()) {
        self.intervals = intervals
        self.metricKit = metricKit
    }

    /// The current process-wide stats plus the latest MetricKit summary.
    public static func current(
        stats: FleetPerformanceStats = .shared,
        metricKit: FleetMetricKitSummaryStore = .shared
    ) -> FleetPerformanceReport {
        FleetPerformanceReport(intervals: stats.summaries(), metricKit: metricKit.latest())
    }
}
