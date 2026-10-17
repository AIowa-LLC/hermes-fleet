import SwiftUI
import FleetCore

/// Review / progress / outcome sheet for a scanned pairing invitation. Shared by
/// first-run and the additional-server sheet; both drive the single
/// `PairingCoordinator` owned by `AppEnvironment`.
struct PairingInvitationReviewSheet: View {
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
                        statusCard("Scan or paste a Hermes link to continue.", symbol: "qrcode.viewfinder")
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
                    case .requesting(let preview):
                        statusCard("Asking \(preview.gateway.origin.host ?? "the server") to connect this phone…", symbol: "lock.shield")
                            .accessibilityIdentifier("fleet.pairing.requesting")
                        ProgressView()
                            .tint(theme.highlight)
                    case .awaitingApproval(let code, let expiresAt):
                        PairingAwaitingApprovalView(
                            code: code, expiresAt: expiresAt,
                            gatewayName: coordinator.pendingRequest?.gateway.displayName,
                            host: coordinator.pendingRequest?.gateway.origin.host,
                            onCancel: { leaveFlow() })
                    case .denied:
                        PairingEndedView(kind: .denied) { leaveFlow() }
                    case .expired:
                        PairingEndedView(kind: .expired) { leaveFlow() }
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
            .navigationTitle("Connect to Hermes")
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
        .interactiveDismissDisabled(!coordinator.canCancel || requiresCleanupRecovery || isAwaitingApproval)
        .fleetHaptic(.pairingComplete, trigger: isPairingCompleted) { _, completed in completed }
        .onDisappear {
            if coordinator.canCancel, !requiresCleanupRecovery { coordinator.dismiss() }
        }
    }

    /// True only once the coordinator reports a successful pairing; drives `pairingComplete`.
    private var isPairingCompleted: Bool {
        if case .completed = coordinator.phase { return true }
        return false
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
                    if preview.approvalRequired {
                        Text("After you tap Connect, Fleet shows a code. Approve it in your chat with Hermes, or in the terminal running `hermes fleet pair`.")
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fleet.pairing.approval-hint")
                    }
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
                         : PairingCopy.message(for: failure, host: host, linkIsPinned: coordinator.linkIsPinned))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.pairing.failure.message")
                }
            }

            if coordinator.canRetry {
                Button(failure == .rollbackUnconfirmed ? "Retry cleanup"
                       : (coordinator.diagnosis?.actionTitle ?? "Retry")) {
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

    private var isAwaitingApproval: Bool {
        if case .awaitingApproval = coordinator.phase { return true }
        return false
    }

    private var requiresCleanupRecovery: Bool {
        if case .failed(.rollbackUnconfirmed, _) = coordinator.phase, coordinator.canRetry { return true }
        return false
    }
}
