import SwiftUI
import UIKit
import FleetCore

/// The first-server screen: "Connect to Hermes". The owner asks Hermes for a link (`/fleet pair`
/// in any chat, or `hermes fleet pair` on the computer), opens it here (tap, scan or paste), and
/// approves the code Fleet shows. This view never asks for a server address or account
/// credentials; those live under "Other ways to connect".
struct QRFirstServerView: View {
    @Environment(\.fleetTheme) private var theme

    private let environment: AppEnvironment
    @Bindable private var pairing: PairingCoordinator
    @State private var presentedSheet: PairingScanSheet?
    @State private var showsOtherWays = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.pairing = environment.pairing
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    brandHeader
                    PairingConnectContent(pairing: pairing, idPrefix: "fleet.first-run", presented: $presentedSheet)
                    expiryNote
                    PairingOtherWaysEntry(idPrefix: "fleet.first-run") { showsOtherWays = true }
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Connect to Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsOtherWays) {
                PairingOtherWaysPage(environment: environment, idPrefix: "fleet.first-run", onCancel: nil)
            }
        }
        .tint(theme.highlight)
        // Refinement Phase 4: no forced dark scheme. The root Appearance
        // preference won for the content but not for sheet chrome, so a light
        // appearance showed white toolbar text on a light sheet.
        .pairingScanSheets(pairing: pairing, presented: $presentedSheet)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            FleetBrandMark(size: 72)

            Text("Connect to Hermes")
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("fleet.first-run.title")

            Text("Fleet connects your phone straight to the Hermes server you run. You approve every connection from your own chat or terminal.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.first-run.intro")

            // Refinement Phase 4: the trust statement sits above the steps,
            // so it is read before anything is asked of the owner.
            OnboardingTrustPoints(idPrefix: "fleet.first-run")
        }
    }

    private var expiryNote: some View {
        Text("Links work once and expire after ten minutes. Opening one only creates a request; this phone is added only after you approve its code.")
            .font(.footnote)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("fleet.first-run.expiry")
    }
}
