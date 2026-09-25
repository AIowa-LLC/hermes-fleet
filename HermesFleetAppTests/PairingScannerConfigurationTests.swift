import XCTest
import VisionKit
import Vision
@testable import FleetUI

/// Build 88 regression guard — the physical-device pairing scanner must be
/// configured for QR BARCODES (VisionKit barcode recognition), never
/// text/OCR. Text recognition never decodes a Hermes pairing QR, so live
/// pairing would silently break on every physical device.
///
/// Note: `DataScannerViewController.RecognizedDataType` is a struct with
/// static factories (`.text(...)`, `.barcode(symbologies:)`) — not an enum —
/// so the guard asserts with `contains(_:)` on factory-built values. Failure
/// modes covered: wrong count, missing QR barcode, text/OCR recognition
/// present.
final class PairingScannerConfigurationTests: XCTestCase {
    func testPairingScannerIsConfiguredForQRBarcodes() {
        let types = PairingScannerConfiguration.recognizedDataTypes
        XCTAssertEqual(
            types.count, 1,
            "pairing scanner must recognize exactly one data type (QR barcodes)")
        XCTAssertTrue(
            types.contains(.barcode(symbologies: [.qr])),
            "pairing scanner must use VisionKit barcode recognition — text/OCR recognition silently breaks live QR pairing")
        XCTAssertFalse(
            types.contains(.text()),
            "text/OCR recognition must never replace the QR barcode path")
    }
}