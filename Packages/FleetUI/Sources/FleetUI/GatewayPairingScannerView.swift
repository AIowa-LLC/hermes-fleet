import SwiftUI
import FleetCore
#if os(iOS)
import UIKit
import VisionKit
#endif

/// F2 — QR pairing scanner sheet for the Add-Gateway flow.
///
/// Presents the system camera barcode/text scanner (VisionKit
/// `DataScannerViewController`). Each recognized text is run through the SAME
/// decode + apply path a simulated scan uses, so the deterministic test hook
/// exercises production logic:
///
///     camera frame ──┐
///                    ├─▶ PairingPayload.decode ─▶ GatewayFormDraftStore.apply
///     simulated tap ─┘
///
/// The sheet is presentation-only: no secret is stored here (the decoded
/// credential lands in the root-owned draft store exactly as if it had been
/// typed), and raw scan text is never logged.
///
/// SECURITY (F2 card): the QR encodes a short-lived scoped credential. The
/// camera preview is live-only — nothing is retained beyond the decoded
/// payload. On a successful apply the sheet dismisses so the QR is never
/// re-scannable from a lingering screen.
struct GatewayPairingScannerView: View {
    @Bindable private var draftStore: GatewayFormDraftStore
    @Environment(\.dismiss) private var dismiss

    /// Non-secret status shown when a scan fails to decode.
    @State private var scanError: String?

    #if os(iOS)
    /// Whether the camera scanner is running (for the stop/start control).
    @State private var isScanning = false
    #endif

    init(draftStore: GatewayFormDraftStore) {
        self.draftStore = draftStore
    }

    var body: some View {
        NavigationStack {
            scannerBody
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("fleet.gateways.scan.cancel")
                    }
                }
        }
        .background(Color.black.ignoresSafeArea())
        .tint(.white)
    }

    @ViewBuilder
    private var scannerBody: some View {
        #if os(iOS)
        if cameraSupported {
            ZStack {
                PairingCameraScanner(
                    onRaw: handleRaw,
                    onCameraError: { scanError = $0; isScanning = false }
                )
                .ignoresSafeArea(edges: .bottom)
                statusOverlay
            }
        } else {
            fallbackBody
        }
        #else
        fallbackBody
        #endif
    }

    /// Live status / error overlay above the camera preview.
    private var statusOverlay: some View {
        VStack {
            Spacer()
            if let scanError {
                Label(scanError, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .accessibilityIdentifier("fleet.gateways.scan.error")
            } else {
                Text("Point the camera at the gateway's pairing QR code")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .accessibilityIdentifier("fleet.gateways.scan.hint")
            }
        }
        .padding(.bottom, 24)
    }

    /// Shown when the live scanner is unavailable (simulator, restricted
    /// device, camera denied): explains why, and — in DEBUG, opt-in via
    /// launch environment — offers the deterministic simulated scan used by
    /// the UI test suite (CI has no camera).
    private var fallbackBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
            Text("Live camera scanning isn't available on this device.\nUse a device with a camera, or enter the gateway details manually.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.gateways.scan.unavailable")

            if let scanError {
                Label(scanError, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.35), in: Capsule())
                    .accessibilityIdentifier("fleet.gateways.scan.error")
            }

            #if DEBUG
            if let simulated = Self.simulatedPayload {
                VStack(spacing: 8) {
                    Text("TEST HOOK (DEBUG)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Button {
                        handleRaw(simulated)
                    } label: {
                        Label("Simulate Scanned Code", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("fleet.gateways.scan.simulate")
                }
                .padding(.top, 8)
            }
            #endif
        }
        .padding(24)
    }

    #if os(iOS)
    /// VisionKit reports support only on real devices with an available
    /// camera; simulators report false (which keeps CI deterministic).
    private var cameraSupported: Bool {
        DataScannerViewController.isSupported
    }
    #endif

    /// The single entry point for ANY scanned string (camera or simulated):
    /// decode, apply to the draft, dismiss on success.
    private func handleRaw(_ raw: String) {
        do {
            try draftStore.applyPairing(raw)
            // Success: leave the scanner so the QR on the Mac screen is not
            // scannable from a lingering camera session, and land the user
            // back on the (now filled) form.
            dismiss()
        } catch PairingPayload.DecodeError.malformedData,
                PairingPayload.DecodeError.notAPairingPayload {
            scanError = "That code is not a Hermes pairing code."
        } catch PairingPayload.DecodeError.unsupportedVersion(let v) {
            scanError = "Pairing code version \(v) is newer than this app supports. Update Hermes Fleet."
        } catch PairingPayload.DecodeError.emptyField {
            scanError = "The pairing code is missing a required field."
        } catch {
            scanError = GatewayFormSheet.nonSecret(error)
        }
    }

    /// DEBUG-only deterministic scan source (UI tests / CI). The value is the
    /// raw QR text, set via the `HERMES_FLEET_PAIRING_SIMULATED_SCAN` launch
    /// environment. Nil in release builds and when not opted in.
    static var simulatedPayload: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"]
        #else
        nil
        #endif
    }
}

#if os(iOS)
/// VisionKit live-scanner bridge. Recognized text is forwarded as-is; decode
/// lives one layer up so camera and simulated scans share one code path.
private struct PairingCameraScanner: UIViewControllerRepresentable {
    var onRaw: (String) -> Void
    var onCameraError: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: false
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onRaw: onRaw, onCameraError: onCameraError)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onRaw: (String) -> Void
        private let onCameraError: (String) -> Void
        /// Same text re-recognized frame after frame — deliver each once.
        private var seen: Set<String> = []

        init(onRaw: @escaping (String) -> Void, onCameraError: @escaping (String) -> Void) {
            self.onRaw = onRaw
            self.onCameraError = onCameraError
        }

        func dataScannerDidBecomeReady(_ dataScanner: DataScannerViewController) {
            do {
                try dataScanner.startScanning()
            } catch {
                onCameraError("Camera unavailable. Check the camera permission in Settings.")
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .text(let text) in addedItems {
                let raw = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, seen.insert(raw).inserted else { continue }
                onRaw(raw)
            }
        }
    }
}
#endif
