import XCTest
@testable import FleetCore

/// Contract tests for `MetadataValue.boundedInt` / `MetadataValue.intValue`,
/// the FleetCore twin of `FleetNetworking.JSONValue.boundedInt`.
///
/// Companion to `MetadataIntegerDecodeBoundaryTests`, which exercises the
/// same bound through the real decode path; these pin the helper contract
/// itself (bounds, non-finite, truncation).
final class MetadataBoundedIntTests: XCTestCase {
    func testUpperBoundIsTwoToTheSixtyThreeExclusive() {
        // The trap door this guards: Double(Int.max) rounds UP to 2^63, so an
        // inclusive Int.max bound would admit the one value Int(_:) cannot take.
        XCTAssertEqual(Double(Int.max), 9_223_372_036_854_775_808.0)
        XCTAssertNil(MetadataValue.boundedInt(9_223_372_036_854_775_808.0))
        XCTAssertNil(MetadataValue.boundedInt(Double(Int.max)))
        // 2^63 - 1024 = 9223372036854774784: the largest Double below 2^63.
        XCTAssertEqual(MetadataValue.boundedInt(9_223_372_036_854_774_784.0),
                       9_223_372_036_854_774_784)
    }

    func testLowerBoundIsTwoToTheSixtyThreeInclusive() {
        XCTAssertEqual(MetadataValue.boundedInt(-9_223_372_036_854_775_808.0), Int.min)
        XCTAssertNil(MetadataValue.boundedInt((-9_223_372_036_854_775_808.0).nextDown))
    }

    func testNonFiniteIsNil() {
        XCTAssertNil(MetadataValue.boundedInt(.infinity))
        XCTAssertNil(MetadataValue.boundedInt(-.infinity))
        XCTAssertNil(MetadataValue.boundedInt(.nan))
    }

    func testInRangeValuesKeepIntTruncationSemantics() {
        XCTAssertEqual(MetadataValue.boundedInt(3.9), 3)
        XCTAssertEqual(MetadataValue.boundedInt(-3.9), -3)
        XCTAssertEqual(MetadataValue.boundedInt(0), 0)
    }

    func testIntValueOnlyReadsNumbers() {
        XCTAssertEqual(MetadataValue.number(7).intValue, 7)
        XCTAssertNil(MetadataValue.number(9_223_372_036_854_775_808.0).intValue)
        XCTAssertNil(MetadataValue.string("7").intValue)
        XCTAssertNil(MetadataValue.bool(true).intValue)
        XCTAssertNil(MetadataValue.null.intValue)
    }
}