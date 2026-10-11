import SwiftUI
import UIKit
import FleetCore

/// The first-server path is intentionally invitation-only. The owner prepares
/// a fresh link on a compatible Hermes host and the phone scans the QR shown
/// there; this view never asks for a server address or account credentials.
struct QRFirstServerView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @Bindable private var pairing: PairingCoordinator
    private enum SetupSheet: String, Identifiable {
        case scanner, review
        var id: String { rawValue }
    }

    @State private var presentedSheet: SetupSheet?
    @State private var didCopyOwnerPrompt = false

    init(pairing: PairingCoordinator) {
        self.pairing = pairing
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    brandHeader
                    scanAction
                    prerequisites
                    setupPrompt
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Connect your first server")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(theme.highlight)
        .preferredColorScheme(.dark)
        .sheet(item: $presentedSheet, onDismiss: sheetDidDismiss) { sheet in
            switch sheet {
            case .scanner:
                GatewayPairingScannerView { rawInvitation in
                    _ = pairing.receive(text: rawInvitation)
                }
            case .review:
                PairingInvitationReviewSheet(coordinator: pairing)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            // Once redeem begins the invitation may already be consumed; the
            // coordinator owns its completion and the review must stay up.
            guard pairing.canCancel, !requiresCleanupRecovery else { return }
            pairing.cancel()
            presentedSheet = nil
        }
        .onChange(of: pairing.isActive) { _, active in
            if !active { presentedSheet = nil }
        }
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            Image("FleetWingMark", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
                .accessibilityLabel("Hermes Fleet wing mark")

            Text("Connect your first server")
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.first-run.title")

            Text("Scan the invitation QR shown on your Hermes host. The phone never needs the owner’s password.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.first-run.intro")
        }
    }

    private var prerequisites: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("Before you begin")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)

                prerequisiteRow(number: "1", text: "Run a compatible Hermes server that is reachable from this phone at a public HTTPS address.")
                prerequisiteRow(number: "2", text: "Open a private Telegram chat with Hermes from the server owner’s account.")
                prerequisiteRow(number: "3", text: "The host must support owner-bound Fleet invitations and display its QR code locally on the computer.")

                Text("Invitations work once and expire after 10 minutes. Scanning only previews the request; this phone is added only after you review and confirm it.")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.first-run.expiry")

                Label {
                    Text("If the host cannot verify its owner, issue a supported invitation, or show the code locally, stop: this server is not ready for Fleet pairing.")
                        .font(.footnote)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(theme.highlight)
                }
                .accessibilityIdentifier("fleet.first-run.readiness")
            }
        }
    }

    private func prerequisiteRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
            Text(number)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(theme.highlight)
                .frame(width: 24, height: 24)
                .background(theme.highlight.opacity(0.14), in: Circle())
            Text(text)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var setupPrompt: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("Message to Hermes")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                Text(Self.ownerPrompt)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.first-run.owner-prompt")
                Button {
                    UIPasteboard.general.string = Self.ownerPrompt
                    didCopyOwnerPrompt = true
                } label: {
                    Label(didCopyOwnerPrompt ? "Copied" : "Copy owner instructions",
                          systemImage: didCopyOwnerPrompt ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.first-run.copy-owner-prompt")
                Text("Copy this message to Hermes in your private Telegram chat while you are at the host computer. Never share the issued link or its secret.")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scanAction: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Button {
                presentedSheet = .scanner
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .foregroundStyle(theme.onHighlight)
            .disabled(!pairing.isAvailable || pairing.isBusy)
            .accessibilityIdentifier("fleet.first-run.scan")

            if !pairing.isAvailable {
                Text("Pairing is not available in this build. Nothing will be added until a supported invitation service is connected.")
                    .font(.footnote)
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.first-run.pairing-unavailable")
            }
        }
    }

    private func sheetDidDismiss() {
        // The scanner hands the raw link to the coordinator and dismisses
        // itself. Present the preview only after the camera sheet is gone.
        if pairing.isActive { presentedSheet = .review }
    }

    private var requiresCleanupRecovery: Bool {
        if case .failed(.rollbackUnconfirmed, _) = pairing.phase, pairing.canRetry { return true }
        return false
    }

    static let ownerPrompt = """
    Please verify that this is a private Telegram conversation with the verified owner who can manage this Hermes server, and that the server supports owner-bound Fleet pairing at a publicly reachable HTTPS address. Issue a fresh, single-use invitation with the installed Hermes command:

    hermes --run-module hermes_cli.fleet_pairing_cli invite --label iPhone --ttl 600

    Pass the exact issued invitation to the installed qrencode program through standard input and display its QR code locally on this host computer. Keep any image private, readable only by the owner, and remove it after the invitation expires. Never put the link or secret in command arguments, shell history, logs, Telegram, or a group. If owner identity, supported issuer, public HTTPS reachability, or local QR display cannot be verified, stop and report that this host is not ready for Fleet pairing.
    """
}

private struct PairingInvitationReviewSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable private var coordinator: PairingCoordinator

    init(coordinator: PairingCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    switch coordinator.phase {
                    case .idle, .awaitingLink:
                        statusCard("Scan an invitation QR code to continue.", symbol: "qrcode.viewfinder")
                    case .previewing(let host):
                        statusCard("Checking the invitation for \(host)…", symbol: "lock.shield")
                            .accessibilityIdentifier("fleet.pairing.previewing")
                        ProgressView()
                            .tint(theme.highlight)
                    case .confirming(let preview):
                        previewContent(preview)
                    case .alreadyAdded(let name):
                        statusCard("\(name) is already in Fleet. This invitation was not used.", symbol: "checkmark.circle")
                        doneButton
                    case .redeeming:
                        statusCard("Finishing the secure server request…", symbol: "lock.shield")
                        ProgressView()
                            .tint(theme.highlight)
                            .accessibilityIdentifier("fleet.pairing.redeeming")
                    case .completed(let name):
                        statusCard("\(name) was added to Fleet.", symbol: "checkmark.circle.fill")
                        doneButton
                    case .failed(let failure, let host):
                        failureContent(failure, host: host)
                    }
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Review invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(coordinator.canCancel ? "Back" : "Connecting…") {
                        leaveFlow()
                    }
                    .disabled(!coordinator.canCancel || requiresCleanupRecovery)
                    .accessibilityIdentifier("fleet.pairing.back")
                }
            }
        }
        .tint(theme.highlight)
        .interactiveDismissDisabled(!coordinator.canCancel || requiresCleanupRecovery)
        .onDisappear {
            if coordinator.canCancel, !requiresCleanupRecovery { coordinator.dismiss() }
        }
    }

    private func previewContent(_ preview: PairingPreview) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    Text("Connect this phone to \(preview.gateway.displayName)?")
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("fleet.pairing.preview.name")
                    Label(preview.gateway.origin.host ?? "Verified HTTPS server", systemImage: "lock.fill")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.pairing.preview.host")
                    Text("The invitation is for this server only, works once, and expires \(preview.expiresAt, style: .relative).")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    Text("Access on this phone")
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(theme.textPrimary)
                    ForEach(Array(preview.access.enumerated()), id: \.offset) { _, access in
                        Label(access.summary, systemImage: "checkmark.shield")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Approve only if you expected this request.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.pairing.permission-explanation")
                }
            }

            Button {
                coordinator.confirm()
            } label: {
                Text("Connect this phone")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .foregroundStyle(theme.onHighlight)
            .accessibilityIdentifier("fleet.pairing.confirm")
        }
    }

    private func failureContent(_ failure: PairingFailure, host: String?) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    Label(PairingCopy.title(for: failure), systemImage: "exclamationmark.triangle")
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    Text(failure == .rollbackUnconfirmed && !coordinator.canRetry
                         ? "This phone couldn't verify cleanup and has no retry available. Ask the owner to check the gateway's device list and revoke this phone before creating or scanning another invitation."
                         : PairingCopy.message(for: failure, host: host))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.pairing.failure.message")
                }
            }

            if coordinator.canRetry {
                Button(failure == .rollbackUnconfirmed ? "Retry cleanup" : "Retry") {
                    coordinator.retry()
                }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.highlight)
                    .accessibilityIdentifier("fleet.pairing.retry")
            }
            if failure != .rollbackUnconfirmed || !coordinator.canRetry {
                Button("Scan another invitation") { leaveFlow() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("fleet.pairing.rescan")
            }
        }
    }

    private func statusCard(_ text: String, symbol: String) -> some View {
        FleetCard {
            Label(text, systemImage: symbol)
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doneButton: some View {
        Button("Done") { leaveFlow() }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .accessibilityIdentifier("fleet.pairing.done")
    }

    private func leaveFlow() {
        guard coordinator.canCancel, !requiresCleanupRecovery else { return }
        coordinator.dismiss()
        dismiss()
    }

    private var requiresCleanupRecovery: Bool {
        if case .failed(.rollbackUnconfirmed, _) = coordinator.phase, coordinator.canRetry { return true }
        return false
    }
}
