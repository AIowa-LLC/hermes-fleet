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
/// field passes through `Redaction.safeDiagnosticText` even though callers pre-redact
/// (belt and braces — a future caller cannot leak by forgetting, and an
/// already-redacted endpoint is simply redacted again, idempotently).
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

    public init(
        generatedAt: Date,
        reportID: String,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        deviceModel: String,
        surfaceContext: String? = nil,
        gateways: [DiagnosticsGatewaySection] = [],
        recentEvents: [DiagnosticsEvent] = []
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
    }
}

/// One gateway's section of the diagnostics report. Every string here is
/// already display-safe at the call site (`Redaction.redactedURL` for
/// `endpointDisplay`) and is re-redacted at render time.
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
        lines.append("Hermes Fleet \(Redaction.safeDiagnosticText(input.appVersion)) (build \(Redaction.safeDiagnosticText(input.appBuild)))")
        lines.append("Report ID: \(Redaction.safeDiagnosticText(input.reportID))")
        lines.append("Generated: \(iso8601(input.generatedAt))")
        lines.append("")

        lines.append("DEVICE")
        lines.append("  OS: \(Redaction.safeDiagnosticText(input.osVersion))")
        lines.append("  Model: \(Redaction.safeDiagnosticText(input.deviceModel))")
        lines.append("")

        let context = Redaction.safeDiagnosticText(input.surfaceContext ?? "")
        lines.append("CONTEXT")
        lines.append("  \(context.isEmpty ? "not captured" : context)")
        lines.append("")

        lines.append("GATEWAYS")
        if input.gateways.isEmpty {
            lines.append("  No gateways configured.")
        } else {
            for section in input.gateways {
                lines.append("  \(Redaction.safeDiagnosticText(section.label))")
                lines.append("    Endpoint: \(Redaction.safeDiagnosticText(section.endpointDisplay))")
                lines.append("    Connection: \(Redaction.safeDiagnosticText(section.connectionState))")
                let capabilities = section.transportCapabilities.map(Redaction.safeDiagnosticText)
                lines.append("    Capabilities: \(capabilities.isEmpty ? "none advertised" : capabilities.joined(separator: ", "))")
                lines.append("    Groups: \(capabilityText(section.groupsCapability))")
                if let roster = section.rosterSummary, !roster.isEmpty {
                    lines.append("    Roster: \(Redaction.safeDiagnosticText(roster))")
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
                lines.append("  \(clock(event.at))  \(Redaction.safeDiagnosticText(event.category)) — \(Redaction.safeDiagnosticText(event.detail))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Free-text normalization

    /// `groups.create` capability text: an unprobed gateway is "unknown"
    /// (fail closed — never "supported" by assumption).
    private static func capabilityText(_ capability: String?) -> String {
        guard let capability else { return "unknown" }
        let safe = Redaction.safeDiagnosticText(capability)
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