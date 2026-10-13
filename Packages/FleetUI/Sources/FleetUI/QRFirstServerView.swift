import SwiftUI
import UIKit
import FleetCore

/// The first-server path is intentionally invitation-only. The owner prepares
/// a fresh link on a compatible Hermes host and the phone scans the QR shown
/// there; this view never asks for a server address or account credentials.
struct QRFirstServerView: View {
    @Environment(\.fleetTheme) private var theme

    @Bindable private var pairing: PairingCoordinator
    @State private var presentedSheet: PairingScanSheet?

    init(pairing: PairingCoordinator) {
        self.pairing = pairing
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    brandHeader
                    PairingScanAction(pairing: pairing, idPrefix: "fleet.first-run") {
                        presentedSheet = .scanner
                    }
                    prerequisites
                    PairingSetupPromptCard(idPrefix: "fleet.first-run")
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
        .pairingScanSheets(pairing: pairing, presented: $presentedSheet)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            FleetBrandMark(size: 72)

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
}
