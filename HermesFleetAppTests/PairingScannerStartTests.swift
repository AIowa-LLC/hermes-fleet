import XCTest
import VisionKit
@testable import FleetUI

/// Build-88 dogfood regression — the pairing scanner must START scanning on
/// appear.
///
/// Root cause fixed here: the previous code called `startScanning()` from
/// `dataScannerDidBecomeReady(_:)` — a method that is NOT part of
/// `DataScannerViewControllerDelegate` (the protocol declares only
/// didAdd/didUpdate/didRemove/didTapOn/didZoom/becameUnavailableWithError;
/// verified against the SDK interface AND the iOS 27 runtime binary, which
/// contains no such selector anywhere), so VisionKit never invoked it and
/// the scanning session never started on a physical device: the camera
/// preview and VisionKit's guidance text ran while no barcode was ever
/// decoded. Live QR pairing could never work.
///
/// Contract pinned here: the scanner container's APPEAR path triggers
/// exactly ONE `startScanning()` attempt (simulators cannot scan, so the
/// attempt outcome is environment-dependent — the deterministic contract is
/// the exactly-once attempt itself, plus honest failure copy whenever the
/// environment refuses the session).
///
/// `@MainActor` is required: VisionKit's `DataScannerViewController` and all
/// UIKit view-controller lifecycle APIs are main-actor isolated.
@MainActor
final class PairingScannerStartTests: XCTestCase {

    private final class FailureBox {
        var messages: [String] = []
    }

    private func makePairingScanner() -> DataScannerViewController {
        DataScannerViewController(
            recognizedDataTypes: Set(PairingScannerConfiguration.recognizedDataTypes),
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: false
        )
    }

    func testAppearStartsScanningExactlyOnce() {
        let box = FailureBox()
        let container = PairingScannerContainerViewController(scanner: makePairingScanner())
        container.onStartFailure = { [box] message in box.messages.append(message) }
        container.loadViewIfNeeded()

        XCTAssertEqual(container.startAttemptCount, 0,
                       "the scanner must not start before the view appears")

        container.viewDidAppear(false)
        XCTAssertEqual(container.startAttemptCount, 1,
                       "appearing must start the scanning session — the dead-callback regression")

        container.viewDidAppear(false)
        XCTAssertEqual(container.startAttemptCount, 1,
                       "the start attempt must happen exactly once")

        // If the environment refused the session (the simulator has no
        // camera), the failure surface must be honest, non-secret copy.
        for message in box.messages {
            XCTAssertEqual(
                message,
                "Camera unavailable. Check the camera permission in Settings.",
                "start failures must surface the honest camera copy")
        }
        XCTAssertLessThanOrEqual(box.messages.count, 1,
                                 "an exactly-once start implies at most one failure")
    }

    func testStartScanningIfNeededIsIdempotent() {
        let container = PairingScannerContainerViewController(scanner: makePairingScanner())
        container.startScanningIfNeeded()
        container.startScanningIfNeeded()
        container.startScanningIfNeeded()
        XCTAssertEqual(container.startAttemptCount, 1,
                       "repeated start calls must not re-attempt the session")
    }
}