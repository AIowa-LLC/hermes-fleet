import SwiftUI
import UIKit
import FleetCore

/// The single maintained "message to Hermes" used by BOTH the first-run
/// screen and the additional-server sheet. Do not duplicate this text.
enum PairingSetupPrompt {
    static let ownerMessage = """
    First verify that this actual incoming event is a private Telegram message from the verified owner who is authorized to manage this Hermes server. A configured allowlist or home channel alone does not prove the sender’s authority. Never accept a group message as authorization.

    Use the maintained Hermes Fleet host release’s documented readiness report with the exact source, runtime source, and Hermes home to verify that a compatible owner-bound Fleet invitation issuer is installed and ready for that selection. This report proves host capability only; it does not prove authority for this Telegram event, forwarding, phone reachability or trust, or local QR display. Verify those separately. Do not assume every Hermes install supports this. If capability is missing, report what is missing and ask the owner to provide or explicitly approve a trusted maintained Fleet host release and its install path. Do not install or activate anything, use a stock Hermes update, copy a single file, guess a download URL or command, or improvise an issuer. Installer activation and live invitation issuance each require explicit owner authority. If readiness or authority cannot be verified, stop without issuing anything.

    Before issuance, verify the configured HTTPS origin matches the host that will appear in the invitation, is reachable from this phone, and presents a certificate trusted by iOS. A private multi-label DNS or tailnet origin can be used when the phone is on that network and trusts the certificate; public internet access and Funnel are not required. Also verify that this computer can display the QR privately and locally. If any check fails, stop and report the specific blocker.

    Only after readiness, the actual owner-bound request, and explicit authority to issue are verified, use the command documented by the ready host tool for its detected Hermes home/runtime to create a fresh, single-use invitation. Do not blindly run a legacy command on every installation. Pass the exact issued link to the QR renderer through standard input and display the QR locally on this computer. Keep it private and remove it after expiry. Never put the link or secret in command arguments, shell history, logs, Telegram, or a group. Return status only; do not transmit the bearer link or secret.
    """
}

/// Sheets the QR pairing flow can present. Shared so first-run and the
/// additional-server sheet drive the same scanner -> review sequence.
enum PairingScanSheet: String, Identifiable {
    case scanner, review
    var id: String { rawValue }
}

/// "Message to Hermes" card: the shared prompt text plus a Copy action.
/// `idPrefix` keeps the accessibility identifiers of each host screen stable
/// (`<prefix>.owner-prompt`, `<prefix>.copy-owner-prompt`).
struct PairingSetupPromptCard: View {
    @Environment(\.fleetTheme) private var theme
    let idPrefix: String
    /// When false the prompt body is clamped with a "Show full message" toggle
    /// so the Copy action stays near the top of a compact sheet.
    var showsFullMessage = true

    @State private var didCopy = false
    @State private var isExpanded = false

    var body: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("Message to Hermes")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                Button {
                    UIPasteboard.general.string = PairingSetupPrompt.ownerMessage
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy setup prompt",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(idPrefix).copy-owner-prompt")
                Text(PairingSetupPrompt.ownerMessage)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(showsFullMessage || isExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(idPrefix).owner-prompt")
                if !showsFullMessage {
                    Button(isExpanded ? "Hide full message" : "Show full message") {
                        isExpanded.toggle()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("\(idPrefix).owner-prompt.toggle")
                }
                Text("Copy this message to Hermes in your private Telegram chat while you are at the host computer. The QR stays on that computer; never send the invitation link or secret through Telegram.")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Scan pairing QR" primary action plus the honest unavailable notice.
struct PairingScanAction: View {
    @Environment(\.fleetTheme) private var theme
    let pairing: PairingCoordinator
    let idPrefix: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Button(action: action) {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .foregroundStyle(theme.onHighlight)
            .disabled(!pairing.isAvailable || pairing.isBusy)
            .accessibilityIdentifier("\(idPrefix).scan")

            if !pairing.isAvailable {
                Text("Pairing is not available in this build. Nothing will be added until a supported invitation service is connected.")
                    .font(.footnote)
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(idPrefix).pairing-unavailable")
            }
        }
    }
}

/// Presents the scanner, then the review sheet once the camera sheet is gone,
/// and backs out of an un-redeemed invitation when the app is backgrounded.
/// Shared by first-run and the additional-server sheet.
struct PairingScanSheets: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var pairing: PairingCoordinator
    @Binding var presented: PairingScanSheet?

    func body(content: Content) -> some View {
        content
            .sheet(item: $presented, onDismiss: sheetDidDismiss) { sheet in
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
                presented = nil
            }
            .onChange(of: pairing.isActive) { _, active in
                if !active { presented = nil }
            }
    }

    private func sheetDidDismiss() {
        // The scanner hands the raw link to the coordinator and dismisses
        // itself. Present the preview only after the camera sheet is gone.
        if pairing.isActive { presented = .review }
    }

    private var requiresCleanupRecovery: Bool {
        if case .failed(.rollbackUnconfirmed, _) = pairing.phase, pairing.canRetry { return true }
        return false
    }
}

extension View {
    func pairingScanSheets(pairing: PairingCoordinator, presented: Binding<PairingScanSheet?>) -> some View {
        modifier(PairingScanSheets(pairing: pairing, presented: presented))
    }
}
