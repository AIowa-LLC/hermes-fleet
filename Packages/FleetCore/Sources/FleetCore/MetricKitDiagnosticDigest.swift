import Foundation

/// A numbers-only digest of one MetricKit diagnostic payload (crash / hang /
/// disk-write / CPU exception counts plus crash signal numbers).
///
/// The app target builds this from `MXDiagnosticPayload`; the digest itself is
/// Foundation-only so its redaction guarantees are host-testable. It never
/// carries call stacks, exception messages, termination reasons, or any other
/// free text: every field is a count or a small POSIX signal number.
public struct MetricKitDiagnosticDigest: Sendable, Equatable {
    /// At most this many distinct signal numbers are kept in a summary.
    public static let maxSignals = 5
    /// POSIX signal numbers are small; anything outside is dropped as noise.
    public static let signalRange = 1...64

    public let crashCount: Int
    /// Distinct crash signal numbers, ascending, capped at `maxSignals`.
    public let crashSignals: [Int]
    public let hangCount: Int
    public let diskWriteExceptionCount: Int
    public let cpuExceptionCount: Int

    /// Counts are clamped to be non-negative; invalid signal numbers are
    /// dropped and the rest are de-duplicated, sorted, and capped.
    public init(
        crashCount: Int,
        crashSignals: [Int] = [],
        hangCount: Int = 0,
        diskWriteExceptionCount: Int = 0,
        cpuExceptionCount: Int = 0
    ) {
        self.crashCount = max(0, crashCount)
        self.crashSignals = Array(
            Set(crashSignals.filter { Self.signalRange.contains($0) })
                .sorted()
                .prefix(Self.maxSignals))
        self.hangCount = max(0, hangCount)
        self.diskWriteExceptionCount = max(0, diskWriteExceptionCount)
        self.cpuExceptionCount = max(0, cpuExceptionCount)
    }

    /// True when the payload reported at least one diagnostic.
    public var hasDiagnostics: Bool {
        crashCount + hangCount + diskWriteExceptionCount + cpuExceptionCount > 0
    }

    /// One-line summary for the diagnostics report's event list. Numbers and
    /// fixed labels only.
    public var summary: String {
        var line = "crashes \(crashCount)"
        if !crashSignals.isEmpty {
            line += " (signals \(crashSignals.map(String.init).joined(separator: ", ")))"
        }
        line += "; hangs \(hangCount); disk-write exceptions \(diskWriteExceptionCount); cpu exceptions \(cpuExceptionCount)"
        return line
    }
}
