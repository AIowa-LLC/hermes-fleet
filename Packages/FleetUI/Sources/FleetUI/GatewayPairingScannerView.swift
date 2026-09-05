import SwiftUI
import FleetCore
#if os(iOS)
import UIKit
import VisionKit
import AVFoundation
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

    #if os(iOS)
    /// Whether the camera scanner is running (for the stop/start control).
    @State private var isScanning = false
    /// C1 hardening: explicit camera permission state — the scanner must
    /// never construct/start a DataScannerViewController while camera access
    /// is denied or restricted (TCC terminates the app if the camera is
    /// touched without a granted authorization AND a usage description).
    /// A denied state shows real recovery copy instead of a dead camera view.
    @State private var cameraPermission: CameraPermission = .undetermined
    #endif

    /// Non-secret status shown when a scan fails to decode (kept outside the
    /// os(iOS) block so the fallback path can surface it too).
    @State private var scanError: String?

    enum CameraPermission { case undetermined, granted, denied }

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
        // DEBUG-only UI-test seam comes FIRST: on the simulator the camera
        // is unsupported, so the forced-denied check must precede the
        // hardware short-circuit to be reachable in CI.
        if Self.forceDeniedForUITest {
            deniedBody
        } else if !cameraSupported {
            // Unsupported hardware (simulator, no camera) short-circuits
            // BEFORE any permission request so the deterministic fallback
            // (and the DEBUG test hook) renders without a TCC prompt on CI
            // simulators.
            fallbackBody
        } else {
            switch cameraPermission {
            case .granted:
                ZStack {
                    PairingCameraScanner(
                        onRaw: handleRaw,
                        onCameraError: { scanError = $0; isScanning = false }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    statusOverlay
                }
            case .denied:
                deniedBody
            case .undetermined:
                // C1 hardening: never touch the camera before authorization
                // resolves. Brief non-spinner placeholder while TCC runs.
                VStack(spacing: FleetTheme.spacingLg) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 44))
                        .foregroundStyle(FleetTheme.textSecondary)
                        .accessibilityHidden(true)
                    Text("Checking camera access…")
                        .font(.callout)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                .padding(FleetTheme.spacingXl)
                .task { await resolveCameraPermission() }
            }
        }
        #else
        fallbackBody
        #endif
    }

    #if os(iOS)
    /// C1 hardening: resolve camera authorization WITHOUT touching the
    /// camera. `AVCaptureDevice.authorizationStatus` is checked first; only
    /// an undetermined status triggers the system prompt
    /// (`requestAccess` presents TCC — the NSCameraUsageDescription in the
    /// app's Info.plist is what makes that prompt legal instead of a kill).
    private func resolveCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraPermission = granted ? .granted : .denied
        default:
            // denied / restricted — surface recovery copy, never the camera.
            cameraPermission = .denied
        }
    }
    #endif

    /// C1 hardening: camera-permission-denied state — real copy and a way
    /// out (deep link to the app's Settings pane), no dead spinner, no
    /// retry surface that could re-trigger TCC.
    private var deniedBody: some View {
        VStack(spacing: FleetTheme.spacingLg) {
            Image(systemName: "video.slash")
                .font(.system(size: 44))
                .foregroundStyle(FleetTheme.statusDegraded)
                .accessibilityHidden(true)
            Text("Camera access is off.\nAllow camera access in Settings to scan pairing codes, or enter the gateway details manually below.")
                .font(.callout)
                .foregroundStyle(FleetTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.gateways.scan.denied")
            Button {
                openSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
            .tint(FleetTheme.accent)
            .accessibilityIdentifier("fleet.gateways.scan.denied.settings")
        }
        .padding(FleetTheme.spacingXl)
    }

    private func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// Live status / error overlay above the camera preview.
    /// U7 (Gold Fleet): gold-accent hint capsule; scan errors keep a high-
    /// contrast black capsule with the degraded-red warning glyph (camera
    /// previews stay legible over any live frame).
    private var statusOverlay: some View {
        VStack {
            Spacer()
            if let scanError {
                Label(scanError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .padding(.horizontal, FleetTheme.spacingLg)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .overlay(Capsule().strokeBorder(FleetTheme.statusDegraded, lineWidth: 1))
                    .accessibilityIdentifier("fleet.gateways.scan.error")
            } else {
                Label(
                    "Point the camera at the gateway's pairing QR code",
                    systemImage: "qrcode.viewfinder"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(FleetTheme.accent)
                .padding(.horizontal, FleetTheme.spacingLg)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(FleetTheme.accent.opacity(0.4), lineWidth: 1))
                .accessibilityIdentifier("fleet.gateways.scan.hint")
            }
        }
        .padding(.bottom, FleetTheme.spacingXl)
    }

    /// Shown when the live scanner is unavailable (simulator, restricted
    /// device, camera denied): explains why, and — in DEBUG, opt-in via
    /// launch environment — offers the deterministic simulated scan used by
    /// the UI test suite (CI has no camera).
    /// U7 (Gold Fleet): token surface — background, gold QR glyph, white
    /// primary text, secondary explainer.
    private var fallbackBody: some View {
        VStack(spacing: FleetTheme.spacingLg) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)
            Text("Live camera scanning isn't available on this device.\nUse a device with a camera, or enter the gateway details manually.")
                .font(.callout)
                .foregroundStyle(FleetTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.gateways.scan.unavailable")

            if let scanError {
                Label(scanError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .padding(.horizontal, FleetTheme.spacingLg)
                    .padding(.vertical, 10)
                    .background(FleetTheme.statusDegraded.opacity(0.35), in: Capsule())
                    .accessibilityIdentifier("fleet.gateways.scan.error")
            }

            #if DEBUG
            if let simulated = Self.simulatedPayload {
                VStack(spacing: FleetTheme.spacingSm) {
                    Text("TEST HOOK (DEBUG)")
                        .font(.caption2)
                        .foregroundStyle(FleetTheme.textSecondary)
                    Button {
                        handleRaw(simulated)
                    } label: {
                        Label("Simulate Scanned Code", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FleetTheme.accent)
                    .accessibilityIdentifier("fleet.gateways.scan.simulate")
                }
                .padding(.top, FleetTheme.spacingSm)
            }
            #endif
        }
        .padding(FleetTheme.spacingXl)
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

    /// DEBUG-only seam (C1 hardening tests): force the camera-denied state
    /// via `HERMES_FLEET_PAIRING_CAMERA_DENIED=1` so the denied recovery UI
    /// is testable on the simulator. Nil/false in release builds.
    static var forceDeniedForUITest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["HERMES_FLEET_PAIRING_CAMERA_DENIED"] == "1"
        #else
        false
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
