import SwiftUI
import UIKit
import FleetCore

/// The single maintained "message to Hermes" used by BOTH the first-run
/// screen and the additional-server sheet. Do not duplicate this text.
enum PairingSetupPrompt {
    static let ownerMessage = """
    Help me set up Hermes Fleet on this host with the Hermes Fleet connector plugin. Only act on this if it is a private Telegram message from the verified owner of this Hermes server; a group message or an allowlist alone is not authority.

    First check whether the Hermes Fleet connector is installed and ready for this host's Hermes version and profile. If it is not, tell me what is missing and ask me to approve a trusted install source. Do not guess a download URL or command, and do not install or change anything without my approval.

    The connector adds the Telegram commands /fleetsetup, /fleetstatus, /fleetqr and /fleetdevices. Use /fleetsetup and /fleetstatus to confirm the setup. Keep my existing owner binding intact. The QR step needs a logged-in macOS desktop session on this computer and an HTTPS address my phone can reach and trust. A private tailnet address works, and public internet access is not required. If any prerequisite is missing, stop and tell me exactly what.

    When setup is ready, I will send /fleetqr myself. The connector opens a private Safari check on this computer to verify phone TLS and that the screen is private, then shows a single-use QR that expires in two minutes. I will scan it with Hermes Fleet and tap Connect this phone. Never send the invitation link or its secret in Telegram, a group, logs, or command arguments. Report status only.
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
