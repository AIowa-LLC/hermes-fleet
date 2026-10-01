import Foundation

/// P0-A "Report a Problem" — the pure value types + renderer behind the
/// sanitized diagnostics report.
///
/// Spec §29 (Logging): diagnostics must never contain WebSocket tickets, API
/// credentials, cookies, or passwords. The report is ASSEMBLED in the UI layer
/// (FleetUI) but RENDERED here so the format is a pure function of its inputs —
/// no view, no device, no clock read beyond the values handed in.
///
/// `DiagnosticsReport.render(_:)` is the last line of defense: every free-text
/// field passes through `Redaction.safeDiagnosticReportText`, which removes
/// credentials and masks complete endpoint URLs before a user shares the
/// report.
public struct DiagnosticsReportInput: Sendable, Equatable {
    /// When the report was assembled (stamped into the header).
    public let generatedAt: Date
    /// The greppable report identity from `DiagnosticsReport.makeReportID`.
    public let reportID: String
    /// `CFBundleShortVersionString` of the running app.
    public let appVersion: String
    /// `CFBundleVersion` of the running app.
    public let appBuild: String
    /// `UIDevice.current.systemVersion` (e.g. "26.0").
    public let osVersion: String
    /// Hardware identifier from `uname()` (e.g. "iPhone17,2").
    public let deviceModel: String
    /// Where the report was captured, when the caller knows. Nil (or empty)
    /// renders as "not captured" — honest absence, never a guess.
    public let surfaceContext: String?
    /// One section per registered gateway, in the caller's stable order.
    public let gateways: [DiagnosticsGatewaySection]
    /// Recent faults, oldest-first (bounded by the recorder).
    public let recentEvents: [DiagnosticsEvent]
    /// F0: interval timings + latest MetricKit summary. Nil renders as
    /// "no performance data supplied" (honest absence).
    public let performance: FleetPerformanceReport?

    public init(
        generatedAt: Date,
        reportID: String,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        deviceModel: String,
        surfaceContext: String? = nil,
        gateways: [DiagnosticsGatewaySection] = [],
        recentEvents: [DiagnosticsEvent] = [],
        performance: FleetPerformanceReport? = nil
    ) {
        self.generatedAt = generatedAt
        self.reportID = reportID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.surfaceContext = surfaceContext
        self.gateways = gateways
        self.recentEvents = recentEvents
        self.performance = performance
    }
}

/// One gateway's section of the diagnostics report. Every string here is
/// display-safe at the call site. The shared report masks endpoint URLs even
/// when the app's local display helpers retain their host for troubleshooting.
public struct DiagnosticsGatewaySection: Sendable, Equatable {
    /// User-facing gateway name.
    public let label: String
    /// Already-redacted endpoint display string, or "not configured".
    public let endpointDisplay: String
    /// §8 connection-state vocabulary (e.g. "Connected", "Sign in required").
    public let connectionState: String
    /// Advertised transport capability strings (sorted, non-secret).
    public let transportCapabilities: [String]
    /// `groups.create` capability, or nil when it was never probed.
    public let groupsCapability: String?
    /// One-line roster outcome summary, or nil when no refresh classified it.
    public let rosterSummary: String?

    public init(
        label: String,
        endpointDisplay: String,
        connectionState: String,
        transportCapabilities: [String] = [],
        groupsCapability: String? = nil,
        rosterSummary: String? = nil
    ) {
        self.label = label
        self.endpointDisplay = endpointDisplay
        self.connectionState = connectionState
        self.transportCapabilities = transportCapabilities
        self.groupsCapability = groupsCapability
        self.rosterSummary = rosterSummary
    }
}

/// One recorded fault line of the diagnostics report.
public struct DiagnosticsEvent: Sendable, Equatable {
    /// When the fault was observed (rendered as UTC `HH:mm:ss`).
    public let at: Date
    /// Short category (e.g. "Gateway connection").
    public let category: String
    /// One-line, non-secret detail.
    public let detail: String

    public init(at: Date, category: String, detail: String) {
        self.at = at
        self.category = category
        self.detail = detail
    }
}

/// Renders (and identifies) the sanitized diagnostics report.
///
/// All timestamps in the rendered text are UTC and the header states the
/// format explicitly (`…Z`), so a report pasted into an issue is unambiguous
/// regardless of where the device was.
public enum DiagnosticsReport {
    /// Maximum rendered event lines (the recorder is bounded too; this is the
    /// render-side guarantee).
    public static let eventLineLimit = 30

    /// A greppable report identity: `DF-<yyMMdd-HHmmss>-<4 uppercase alnum>`.
    ///
    /// The `suffix` is normalized (uppercased, non-ASCII-alphanumeric dropped,
    /// first 4 kept) and zero-padded to exactly 4 characters, so the format
    /// holds even for a caller that supplies a short or empty token.
    public static func makeReportID(now: Date, suffix: String) -> String {
        "DF-\(stamp(now))-\(normalizedSuffix(suffix))"
    }

    /// Render the structured plain-text report.
    ///
    /// Section content is honest about absence: "No gateways configured." and
    /// "No recent errors." are real sentences, never an empty section.
    public static func render(_ input: DiagnosticsReportInput) -> String {
        var lines: [String] = []

        // Header — identity + the three facts a maintainer asks for first.
        lines.append("Hermes Fleet \(Redaction.safeDiagnosticReportText(input.appVersion)) (build \(Redaction.safeDiagnosticReportText(input.appBuild)))")
        lines.append("Report ID: \(Redaction.safeDiagnosticReportText(input.reportID))")
        lines.append("Generated: \(iso8601(input.generatedAt))")
        lines.append("")

        lines.append("DEVICE")
        lines.append("  OS: \(Redaction.safeDiagnosticReportText(input.osVersion))")
        lines.append("  Model: \(Redaction.safeDiagnosticReportText(input.deviceModel))")
        lines.append("")

        let context = Redaction.safeDiagnosticReportText(input.surfaceContext ?? "")
        lines.append("CONTEXT")
        lines.append("  \(context.isEmpty ? "not captured" : context)")
        lines.append("")

        lines.append("PERFORMANCE")
        lines.append(contentsOf: performanceLines(input.performance))
        lines.append("")

        lines.append("GATEWAYS")
        if input.gateways.isEmpty {
            lines.append("  No gateways configured.")
        } else {
            for section in input.gateways {
                lines.append("  \(Redaction.safeDiagnosticReportText(section.label))")
                lines.append("    Endpoint: \(Redaction.safeDiagnosticReportText(section.endpointDisplay))")
                lines.append("    Connection: \(Redaction.safeDiagnosticReportText(section.connectionState))")
                let capabilities = section.transportCapabilities.map(Redaction.safeDiagnosticReportText)
                lines.append("    Capabilities: \(capabilities.isEmpty ? "none advertised" : capabilities.joined(separator: ", "))")
                lines.append("    Groups: \(capabilityText(section.groupsCapability))")
                if let roster = section.rosterSummary, !roster.isEmpty {
                    lines.append("    Roster: \(Redaction.safeDiagnosticReportText(roster))")
                }
            }
        }
        lines.append("")

        // Newest `eventLineLimit` events, kept oldest-first.
        let events = Array(input.recentEvents.suffix(eventLineLimit))
        lines.append("RECENT EVENTS")
        if events.isEmpty {
            lines.append("  No recent errors.")
        } else {
            for event in events {
                lines.append("  \(clock(event.at))  \(Redaction.safeDiagnosticReportText(event.category)) — \(Redaction.safeDiagnosticReportText(event.detail))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Performance (F0)

    /// The PERFORMANCE section body. Numbers and closed-vocabulary labels
    /// only; every string still passes the report redactor.
    static func performanceLines(_ performance: FleetPerformanceReport?) -> [String] {
        guard let performance else { return ["  no performance data supplied"] }
        var lines: [String] = []
        for summary in performance.intervals {
            let name = Redaction.safeDiagnosticReportText(summary.interval.rawValue)
            guard summary.completedCount > 0,
                  let low = summary.minMilliseconds,
                  let median = summary.medianMilliseconds,
                  let high = summary.maxMilliseconds else {
                lines.append("  \(name): no completed samples\(outcomeSuffix(summary))")
                continue
            }
            lines.append("  \(name): n=\(summary.completedCount) min \(milliseconds(low)) / median \(milliseconds(median)) / max \(milliseconds(high))\(outcomeSuffix(summary))")
        }
        let kit = performance.metricKit
        if kit.isEmpty {
            lines.append("  MetricKit: none received yet")
        }
        if let metrics = kit.metrics {
            lines.append("  MetricKit metrics (received \(iso8601(metrics.receivedAt))):")
            appendMetric(&lines, "Foreground time", metrics.foregroundSeconds, unit: "s")
            appendMetric(&lines, "Launch to first draw (median)", metrics.medianTimeToFirstDrawMilliseconds, unit: "ms")
            appendMetric(&lines, "Resume (median)", metrics.medianResumeTimeMilliseconds, unit: "ms")
            appendMetric(&lines, "Hang time (median)", metrics.medianHangTimeMilliseconds, unit: "ms")
            appendMetric(&lines, "Peak memory", metrics.peakMemoryMegabytes, unit: "MB")
            appendMetric(&lines, "Logical writes", metrics.logicalWritesMegabytes, unit: "MB")
        }
        if let diagnostics = kit.diagnostics {
            lines.append("  MetricKit diagnostics (received \(iso8601(diagnostics.receivedAt))):")
            lines.append("    Crashes: \(max(0, diagnostics.crashCount))")
            lines.append("    Hangs: \(max(0, diagnostics.hangCount))")
            lines.append("    Disk-write exceptions: \(max(0, diagnostics.diskWriteExceptionCount))")
            lines.append("    CPU exceptions: \(max(0, diagnostics.cpuExceptionCount))")
        }
        return lines
    }

    private static func outcomeSuffix(_ summary: FleetIntervalSummary) -> String {
        var parts: [String] = []
        if summary.failedCount > 0 { parts.append("\(summary.failedCount) failed") }
        if summary.cancelledCount > 0 { parts.append("\(summary.cancelledCount) cancelled") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func appendMetric(_ lines: inout [String], _ label: String, _ value: Double?, unit: String) {
        guard let value, value.isFinite, value >= 0 else { return }
        lines.append("    \(label): \(String(format: "%.0f", value)) \(unit)")
    }

    private static func milliseconds(_ value: Double) -> String {
        guard value.isFinite else { return "n/a" }
        return "\(String(format: "%.0f", max(0, value))) ms"
    }

    // MARK: - Free-text normalization

    /// `groups.create` capability text: an unprobed gateway is "unknown"
    /// (fail closed — never "supported" by assumption).
    private static func capabilityText(_ capability: String?) -> String {
        guard let capability else { return "unknown" }
        let safe = Redaction.safeDiagnosticReportText(capability)
        return safe.isEmpty ? "unknown" : safe
    }

    /// Uppercase ASCII alphanumerics only, exactly 4 characters.
    private static func normalizedSuffix(_ suffix: String) -> String {
        let cleaned = suffix.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let taken = String(cleaned.prefix(4))
        guard taken.count < 4 else { return taken }
        return taken + String(repeating: "0", count: 4 - taken.count)
    }

    // MARK: - UTC formatting (no DateFormatter: deterministic, locale-free)

    private static var utcTimeZone: TimeZone {
        TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
    }

    private static func utcComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func pad2(_ value: Int?) -> String {
        String(format: "%02d", value ?? 0)
    }

    /// `yyMMdd-HHmmss` — the report-ID stamp.
    private static func stamp(_ date: Date) -> String {
        let c = utcComponents(date)
        return "\(pad2((c.year ?? 0) % 100))\(pad2(c.month))\(pad2(c.day))-\(pad2(c.hour))\(pad2(c.minute))\(pad2(c.second))"
    }

    /// `yyyy-MM-ddTHH:mm:ssZ` — the header timestamp.
    private static func iso8601(_ date: Date) -> String {
        let c = utcComponents(date)
        return "\(String(format: "%04d", c.year ?? 0))-\(pad2(c.month))-\(pad2(c.day))T\(pad2(c.hour)):\(pad2(c.minute)):\(pad2(c.second))Z"
    }

    /// `HH:mm:ss` — one event line's clock.
    private static func clock(_ date: Date) -> String {
        let c = utcComponents(date)
        return "\(pad2(c.hour)):\(pad2(c.minute)):\(pad2(c.second))"
    }
}
