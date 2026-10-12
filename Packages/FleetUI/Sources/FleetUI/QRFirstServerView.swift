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

                prerequisiteRow(number: "1", text: "Run a compatible Hermes host with an HTTPS address this phone can reach and a certificate iOS trusts. A private tailnet address works when this phone is a member and trusts the certificate; public internet access or Funnel is not required.")
                prerequisiteRow(number: "2", text: "Open a private Telegram chat with Hermes from the server owner’s account.")
                prerequisiteRow(number: "3", text: "The maintained Fleet host release must report a ready, owner-bound invitation issuer for the active Hermes home/runtime, and the computer must be able to display the QR locally.")

                Text("Invitations work once and expire after 10 minutes. Scanning only previews the request; this phone is added only after you review and confirm it.")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.first-run.expiry")

                Label {
                    Text("If readiness is missing, ask the owner to provide or explicitly approve a trusted maintained Fleet host release and install path. Do not use a stock Hermes update, copy a single file, or guess an issuer command. Stop if the owner-bound request, phone-reachable HTTPS origin, or private local display cannot be verified.")
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
                Text("Copy this message to Hermes in your private Telegram chat while you are at the host computer. The QR stays on that computer; never send the invitation link or secret through Telegram.")
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
    First verify that this actual incoming event is a private Telegram message from the verified owner who is authorized to manage this Hermes server. A configured allowlist or home channel alone does not prove the sender’s authority. Never accept a group message as authorization.

    Use the maintained Hermes Fleet host release’s documented readiness report with the exact source, runtime source, and Hermes home to verify that a compatible owner-bound Fleet invitation issuer is installed and ready for that selection. This report proves host capability only; it does not prove authority for this Telegram event, forwarding, phone reachability or trust, or local QR display. Verify those separately. Do not assume every Hermes install supports this. If capability is missing, report what is missing and ask the owner to provide or explicitly approve a trusted maintained Fleet host release and its install path. Do not install or activate anything, use a stock Hermes update, copy a single file, guess a download URL or command, or improvise an issuer. Installer activation and live invitation issuance each require explicit owner authority. If readiness or authority cannot be verified, stop without issuing anything.

    Before issuance, verify the configured HTTPS origin matches the host that will appear in the invitation, is reachable from this phone, and presents a certificate trusted by iOS. A private multi-label DNS or tailnet origin can be used when the phone is on that network and trusts the certificate; public internet access and Funnel are not required. Also verify that this computer can display the QR privately and locally. If any check fails, stop and report the specific blocker.

    Only after readiness, the actual owner-bound request, and explicit authority to issue are verified, use the command documented by the ready host tool for its detected Hermes home/runtime to create a fresh, single-use invitation. Do not blindly run a legacy command on every installation. Pass the exact issued link to the QR renderer through standard input and display the QR locally on this computer. Keep it private and remove it after expiry. Never put the link or secret in command arguments, shell history, logs, Telegram, or a group. Return status only; do not transmit the bearer link or secret.
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
