import XCTest
import Foundation
@testable import FleetCore

/// Redaction and bounding for the numbers-only MetricKit diagnostic digest.
final class MetricKitDiagnosticDigestTests: XCTestCase {
    func testEmptyDigestHasNoDiagnosticsAndHonestSummary() {
        let digest = MetricKitDiagnosticDigest(crashCount: 0)
        XCTAssertFalse(digest.hasDiagnostics)
        XCTAssertEqual(
            digest.summary,
            "crashes 0; hangs 0; disk-write exceptions 0; cpu exceptions 0")
    }

    func testNegativeCountsClampToZero() {
        let digest = MetricKitDiagnosticDigest(
            crashCount: -4, hangCount: -1, diskWriteExceptionCount: -2, cpuExceptionCount: -3)
        XCTAssertEqual(digest.crashCount, 0)
        XCTAssertEqual(digest.hangCount, 0)
        XCTAssertEqual(digest.diskWriteExceptionCount, 0)
        XCTAssertEqual(digest.cpuExceptionCount, 0)
        XCTAssertFalse(digest.hasDiagnostics)
    }

    func testSignalsAreDedupedSortedAndRangeChecked() {
        let digest = MetricKitDiagnosticDigest(
            crashCount: 4,
            crashSignals: [11, 6, 11, 0, -1, 65, 1000, 6])
        XCTAssertEqual(digest.crashSignals, [6, 11])
    }

    func testSignalsAreCappedAtMaxSignals() {
        let digest = MetricKitDiagnosticDigest(
            crashCount: 9, crashSignals: Array(1...20))
        XCTAssertEqual(digest.crashSignals.count, MetricKitDiagnosticDigest.maxSignals)
        XCTAssertEqual(digest.crashSignals, [1, 2, 3, 4, 5])
    }

    func testSummaryCarriesOnlyNumbersAndFixedLabels() {
        let digest = MetricKitDiagnosticDigest(
            crashCount: 2, crashSignals: [11], hangCount: 1,
            diskWriteExceptionCount: 3, cpuExceptionCount: 4)
        XCTAssertTrue(digest.hasDiagnostics)
        XCTAssertEqual(
            digest.summary,
            "crashes 2 (signals 11); hangs 1; disk-write exceptions 3; cpu exceptions 4")
        // Nothing free-text can appear: only digits, commas, spaces, and the
        // fixed labels. A redaction pass must leave it untouched.
        let allowed = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: " ,;()-"))
            .union(CharacterSet.letters)
        XCTAssertTrue(digest.summary.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(Redaction.safeDiagnosticText(digest.summary), digest.summary)
    }
}
