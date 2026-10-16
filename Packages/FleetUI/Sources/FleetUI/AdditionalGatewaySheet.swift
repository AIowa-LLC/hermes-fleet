import SwiftUI
import FleetCore

/// Add-another-server sheet, presented from Settings and the Gateways tab once
/// at least one gateway is saved. It shows the same "Connect to Hermes" content as first-run
/// (shared steps, scan/paste actions, review sheet and `PairingCoordinator`), and keeps the
/// owner sign-in, manual form and legacy setup message under "Other ways to connect".
///
/// Cancelling, retrying or rescanning here never touches saved gateways and
/// never returns the app to first-run onboarding: the root gate is driven only
/// by the registry being empty.
struct AdditionalGatewaySheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let environment: AppEnvironment

    @State private var presentedScanSheet: PairingScanSheet?
    @State private var showsAdvanced = false
    @State private var baselineGatewayCount = 0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    header
                    PairingConnectContent(
                        pairing: environment.pairing, idPrefix: "fleet.add-gateway", presented: $presentedScanSheet)
                    Text("Links work once and expire after ten minutes. Opening one only creates a request; this phone is added only after you approve its code. Your existing servers are not changed.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.add-gateway.expiry")
                    advancedEntry
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Connect to Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .accessibilityIdentifier("fleet.add-gateway.cancel")
                }
            }
            .navigationDestination(isPresented: $showsAdvanced) {
                PairingOtherWaysPage(environment: environment, idPrefix: "fleet.add-gateway") { cancel() }
            }
        }
        .tint(theme.highlight)
        .pairingScanSheets(pairing: environment.pairing, presented: $presentedScanSheet)
        .onAppear {
            baselineGatewayCount = environment.gateways.count
            // A manual form can outlive this view's @State during the Face ID
            // lock teardown; reopen its page (the page restores the form, never credentials).
            if environment.gatewayFormDraft.pendingSheet == .add { showsAdvanced = true }
        }
        .onChange(of: environment.gateways.count) { _, _ in finishIfGatewayAdded() }
        .onChange(of: environment.pairing.isActive) { _, _ in finishIfGatewayAdded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            FleetBrandMark(size: 56)
            Text("Connect to Hermes")
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.add-gateway.title")
            Text("Add another Hermes server. Ask it for a link, open the link here, and approve the code Fleet shows.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.add-gateway.intro")
        }
    }

    private var advancedEntry: some View {
        PairingOtherWaysEntry(idPrefix: "fleet.add-gateway") { showsAdvanced = true }
    }

    /// Back out of any un-redeemed invitation and close. Saved gateways stay.
    private func cancel() {
        if environment.pairing.isActive, environment.pairing.canCancel {
            environment.pairing.dismiss()
        }
        dismiss()
    }

    /// Close once a gateway was added by any route. Never while the pairing
    /// outcome card is still up, so the person sees the result first.
    private func finishIfGatewayAdded() {
        guard environment.gateways.count > baselineGatewayCount, !environment.pairing.isActive else { return }
        dismiss()
    }
}
