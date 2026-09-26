import XCTest
import Foundation
@testable import FleetCore

/// P0-A — the sanitized diagnostics report: format, honesty, and the
/// redaction guarantee that makes the report safe to paste into an issue.
final class DiagnosticsReportTests: XCTestCase {

    /// Fixed instant: 2023-11-14T22:13:20Z (verified against the UTC calendar).
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeInput(
        gateways: [DiagnosticsGatewaySection] = [],
        recentEvents: [DiagnosticsEvent] = [],
        surfaceContext: String? = nil,
        reportID: String = "DF-231114-221320-A1B2"
    ) -> DiagnosticsReportInput {
        DiagnosticsReportInput(
            generatedAt: fixedNow,
            reportID: reportID,
            appVersion: "0.2.0",
            appBuild: "83",
            osVersion: "26.0",
            deviceModel: "iPhone17,2",
            surfaceContext: surfaceContext,
            gateways: gateways,
            recentEvents: recentEvents)
    }

    // MARK: - Header / device / context

    func testRenderCarriesVersionBuildReportIDAndDeviceLines() {
        let text = DiagnosticsReport.render(makeInput())
        XCTAssertTrue(text.contains("Hermes Fleet 0.2.0 (build 83)"),
                      "header must carry app version and build: \(text)")
        XCTAssertTrue(text.contains("Report ID: DF-231114-221320-A1B2"),
                      "header must carry the report id: \(text)")
        XCTAssertTrue(text.contains("Generated: 2023-11-14T22:13:20Z"),
                      "header must carry the UTC generation stamp: \(text)")
        XCTAssertTrue(text.contains("OS: 26.0"), "device OS must render: \(text)")
        XCTAssertTrue(text.contains("Model: iPhone17,2"), "device model must render: \(text)")
    }

    func testMissingSurfaceContextRendersHonestNotCaptured() {
        let text = DiagnosticsReport.render(makeInput(surfaceContext: nil))
        XCTAssertTrue(text.contains("CONTEXT\n  not captured"),
                      "an absent surface context must say so: \(text)")

        let captured = DiagnosticsReport.render(makeInput(surfaceContext: "Settings"))
        XCTAssertTrue(captured.contains("CONTEXT\n  Settings"))
        XCTAssertFalse(captured.contains("not captured"))
    }

    // MARK: - Gateways

    func testGatewaySectionRendersEveryFactAndIsHonestWhenEmpty() {
        let text = DiagnosticsReport.render(makeInput(gateways: [
            DiagnosticsGatewaySection(
                label: "MacBook",
                endpointDisplay: "https://gateway.example:8765/private/path",
                connectionState: "Connected",
                transportCapabilities: ["change_events", "heartbeat"],
                groupsCapability: "supported",
                rosterSummary: "answered — 3 bots"),
            DiagnosticsGatewaySection(
                label: "Arch",
                endpointDisplay: "not configured",
                connectionState: "Unavailable from this phone",
                transportCapabilities: [],
                groupsCapability: nil,
                rosterSummary: nil),
        ]))

        XCTAssertTrue(text.contains("  MacBook"), text)
        XCTAssertTrue(text.contains("    Endpoint: [ENDPOINT REDACTED]"), text)
        XCTAssertFalse(text.contains("gateway.example"), text)
        XCTAssertFalse(text.contains("private/path"), text)
        XCTAssertTrue(text.contains("    Connection: Connected"), text)
        XCTAssertTrue(text.contains("    Capabilities: change_events, heartbeat"), text)
        XCTAssertTrue(text.contains("    Groups: supported"), text)
        XCTAssertTrue(text.contains("    Roster: answered — 3 bots"), text)

        XCTAssertTrue(text.contains("    Endpoint: not configured"), text)
        XCTAssertTrue(text.contains("    Capabilities: none advertised"), text)
        XCTAssertTrue(text.contains("    Groups: unknown"),
                      "an unprobed groups capability is unknown, never supported: \(text)")
        XCTAssertFalse(text.contains("Roster: \n"), "a nil roster summary renders no row")
        XCTAssertFalse(text.contains("No gateways configured."), text)

        let empty = DiagnosticsReport.render(makeInput())
        XCTAssertTrue(empty.contains("GATEWAYS\n  No gateways configured."),
                      "an empty fleet says so in a real sentence: \(empty)")
    }

    // MARK: - Redaction (the reason this report is safe to share)

    func testGatewaySecretsNeverRender() {
        let text = DiagnosticsReport.render(makeInput(gateways: [
            DiagnosticsGatewaySection(
                label: "MacBook token=abc12345",
                endpointDisplay: "https://user:pass@gateway.example:8765/private/path?ticket=SECRETVALUE",
                connectionState: "Unavailable from this phone",
                transportCapabilities: ["heartbeat"],
                groupsCapability: "unsupported: ticket=SECRETVALUE",
                rosterSummary: "failed: https://gateway.example/private/path?token=abc12345"),
        ]))

        for secret in ["abc12345", "SECRETVALUE", "user:pass@", "gateway.example", "private/path"] {
            XCTAssertFalse(text.contains(secret),
                           "\(secret) must never render in the report: \(text)")
        }
        XCTAssertTrue(text.contains(Redaction.placeholder),
                      "the redaction placeholder must mark what was removed: \(text)")
    }

    func testEventSecretsNeverRender() {
        let text = DiagnosticsReport.render(makeInput(recentEvents: [
            DiagnosticsEvent(
                at: fixedNow,
                category: "Gateway connection",
                detail: "Couldn't reach MacBook at https://user:pass@host/?ticket=SECRETVALUE — token=abc12345"),
        ]))

        for secret in ["abc12345", "SECRETVALUE", "user:pass@"] {
            XCTAssertFalse(text.contains(secret), "\(secret) must never render: \(text)")
        }
        XCTAssertTrue(text.contains("[ENDPOINT REDACTED]"), text)
        XCTAssertFalse(text.contains("host/"), text)
        XCTAssertTrue(text.contains("token=[REDACTED]"), text)
    }

    // MARK: - Events

    func testEventLinesUseClockCategoryAndDetail() {
        let text = DiagnosticsReport.render(makeInput(recentEvents: [
            DiagnosticsEvent(at: fixedNow, category: "Gateway connection", detail: "Offline"),
            DiagnosticsEvent(at: fixedNow, category: "Roster refresh", detail: "Timed out"),
        ]))
        XCTAssertTrue(text.contains("  22:13:20  Gateway connection — Offline"), text)
        XCTAssertTrue(text.contains("  22:13:20  Roster refresh — Timed out"), text)
        XCTAssertFalse(text.contains("No recent errors."), text)

        let empty = DiagnosticsReport.render(makeInput())
        XCTAssertTrue(empty.contains("RECENT EVENTS\n  No recent errors."),
                      "an empty event ring says so in a real sentence: \(empty)")
    }

    func testEventsAreCappedAtThirtyNewestKept() {
        // 40 events, one per second, oldest first.
        let events = (0..<40).map { index in
            DiagnosticsEvent(
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                category: "Event \(index)",
                detail: "detail \(index)")
        }
        let text = DiagnosticsReport.render(makeInput(recentEvents: events))

        let rendered = text.components(separatedBy: "\n").filter { $0.contains("— detail ") }
        XCTAssertEqual(rendered.count, DiagnosticsReport.eventLineLimit)
        XCTAssertFalse(text.contains("Event 0 — detail 0"), text)
        XCTAssertTrue(text.contains("Event 39 — detail 39"), text)

        let lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.contains("Event 10 — detail 10") }),
              let last = lines.firstIndex(where: { $0.contains("Event 39 — detail 39") }) else {
            return XCTFail("expected the newest 30 events:\n\(text)")
        }
        XCTAssertLessThan(first, last, "events stay oldest-first")
    }

    // MARK: - Report ID

    func testReportIDFormat() {
        let id = DiagnosticsReport.makeReportID(now: fixedNow, suffix: "a1b2")
        XCTAssertEqual(id, "DF-231114-221320-A1B2")

        // Exactly 4 uppercase-alnum characters, whatever the caller supplies.
        let messy = DiagnosticsReport.makeReportID(now: fixedNow, suffix: "z9#8!k7")
        XCTAssertEqual(messy, "DF-231114-221320-Z98K")
        XCTAssertEqual(messy.split(separator: "-").last?.count, 4,
                       "the id ends in exactly 4 uppercase alnum characters: \(messy)")

        let short = DiagnosticsReport.makeReportID(now: fixedNow, suffix: "ab")
        guard let suffix = short.components(separatedBy: "-").last else {
            return XCTFail("expected three hyphen-separated groups, got \(short)")
        }
        XCTAssertEqual(suffix.count, 4, "the format holds even for a short suffix: \(short)")
        XCTAssertEqual(short, "DF-231114-221320-AB00")

        let empty = DiagnosticsReport.makeReportID(now: fixedNow, suffix: "")
        XCTAssertEqual(empty, "DF-231114-221320-0000")
    }

    func testReportIDIsPrefixStableAndMonotonicStamped() {
        let later = DiagnosticsReport.makeReportID(
            now: Date(timeIntervalSince1970: 1_700_000_000 + 61), suffix: "0001")
        XCTAssertEqual(later, "DF-231114-221421-0001")
        XCTAssertEqual(DiagnosticsReport.makeReportID(now: fixedNow, suffix: "ABCD").prefix(3), "DF-")
    }
}
