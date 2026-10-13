import SwiftUI
import FleetCore

/// Add-another-server sheet, presented from Settings and the Gateways tab once
/// at least one gateway is saved. It teaches the same QR-first path as first-run
/// (shared prompt card, scan action, review sheet and `PairingCoordinator`),
/// and keeps the owner sign-in and manual form reachable under Advanced setup.
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
    @State private var showsOwnerSignIn = false
    @State private var showsManualForm = false
    @State private var baselineGatewayCount = 0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    header
                    PairingScanAction(pairing: environment.pairing, idPrefix: "fleet.add-gateway") {
                        presentedScanSheet = .scanner
                    }
                    PairingSetupPromptCard(idPrefix: "fleet.add-gateway", showsFullMessage: false)
                    Text("Invitations work once and expire shortly. Scanning only previews the request; this phone is added only after you review and confirm it. Your existing servers are not changed.")
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
            .navigationTitle("Add a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .accessibilityIdentifier("fleet.add-gateway.cancel")
                }
            }
            .navigationDestination(isPresented: $showsAdvanced) { advancedPage }
        }
        .tint(theme.highlight)
        .pairingScanSheets(pairing: environment.pairing, presented: $presentedScanSheet)
        .sheet(isPresented: $showsOwnerSignIn) {
            GatewayOnboardingView(environment: environment, canDismiss: true)
        }
        .sheet(isPresented: $showsManualForm) {
            GatewayFormSheet(
                title: "Advanced Gateway Setup",
                saveButton: "Add",
                initial: nil,
                draftStore: environment.gatewayFormDraft
            ) { registration, credential, confirmsTLSFirstUse in
                _ = try await environment.addGateway(
                    registration,
                    credential: credential,
                    confirmsTLSFirstUse: confirmsTLSFirstUse)
            }
        }
        .onAppear {
            baselineGatewayCount = environment.gateways.count
            // A manual form can outlive this view's @State during the Face ID
            // lock teardown; restore only that presentation (never credentials).
            if environment.gatewayFormDraft.pendingSheet == .add {
                showsAdvanced = true
                showsManualForm = true
            }
        }
        .onChange(of: environment.gateways.count) { _, _ in finishIfGatewayAdded() }
        .onChange(of: environment.pairing.isActive) { _, _ in finishIfGatewayAdded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            FleetBrandMark(size: 56)
            Text("Add another server")
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.add-gateway.title")
            Text("Scan the invitation QR shown on your Hermes host. The phone never needs the owner’s password.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.add-gateway.intro")
        }
    }

    private var advancedEntry: some View {
        Button {
            showsAdvanced = true
        } label: {
            Label("Advanced setup", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("fleet.add-gateway.advanced")
    }

    private var advancedPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                Text("Use these only if the QR invitation route does not fit your server.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showsOwnerSignIn = true
                } label: {
                    Label("Sign in as the server owner", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.add-gateway.advanced.owner")
                Button {
                    environment.gatewayFormDraft.begin(pendingSheet: .add, initial: nil)
                    showsManualForm = true
                } label: {
                    Label("Enter gateway details manually", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.add-gateway.advanced.manual")
            }
            .padding(FleetTheme.spacingXl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Advanced setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { cancel() }
                    .accessibilityIdentifier("fleet.add-gateway.advanced.cancel")
            }
        }
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
