import SwiftUI
import FleetCore
#if canImport(UIKit)
import UIKit
#endif

/// "Add to Fleet": the screen for a pairing invitation, shown for a link opened from outside
/// the app (root presenter) and for "Add with Pairing Link" inside Add Gateway.
///
/// What the person sees before anything is granted: which gateway (name and exact address)
/// and what access it asks for, in the app's own words. Nothing is consumed or approved until
/// they tap **Add to Fleet** on the confirmation screen.
struct PairingSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var coordinator: PairingCoordinator
    /// Whether to offer the QR scanner.
    var allowsScan = true
    /// Called when the sheet should go away. The flag is true when the gateway was added (or was
    /// already there), so the presenter can also close the screen it was opened from.
    var onClose: (_ added: Bool) -> Void

    @State private var pastedText = ""
    @State private var isShowingScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    content
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Add to Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if coordinator.canCancel {
                        Button(isFinished ? "Done" : "Cancel") { close() }
                        .accessibilityIdentifier("fleet.pairing.close")
                    }
                }
            }
        }
        .tint(theme.highlight)
        .interactiveDismissDisabled(!coordinator.canCancel)
        .accessibilityIdentifier("fleet.pairing.sheet")
        .sheet(isPresented: $isShowingScanner) {
            GatewayPairingScannerView(draftStore: nil) { raw in
                coordinator.receive(text: raw, entry: coordinator.entry)
            }
        }
    }

    /// Close the flow: remember whether it ended with the gateway in Fleet, reset, tell the presenter.
    private func close() {
        let added: Bool
        switch coordinator.phase {
        case .completed, .alreadyAdded: added = true
        default: added = false
        }
        coordinator.dismiss()
        onClose(added)
    }

    private var isFinished: Bool {
        switch coordinator.phase {
        case .completed, .failed, .alreadyAdded: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle, .awaitingLink:
            entry
        case .previewing(let host):
            progress("Checking \(host)…", detail: "Nothing is added or approved yet.")
        case .confirming(let preview):
            confirmation(preview)
        case .redeeming(let preview):
            progress("Adding \(preview.gateway.displayName)…",
                     detail: "Keep this screen open until it finishes.")
        case .completed(let name):
            outcome(
                symbol: "checkmark.circle.fill", tint: FleetTheme.statusOnline,
                title: "Added to Fleet",
                message: "\(name) is now in your fleet. This phone has its own credential for it, stored in Keychain; you can revoke it from the gateway at any time.",
                id: "completed")
        case .alreadyAdded(let name):
            outcome(
                symbol: "checkmark.seal", tint: theme.highlight,
                title: "Already in Fleet",
                message: "\(name) is already in your fleet, so nothing was changed and the link was not used.",
                id: "already-added")
        case .failed(let failure, let host):
            failed(failure, host: host)
        }
    }

    // MARK: Entry (paste / scan)

    private var entry: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
            Text("Add a gateway with a pairing link")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Text("Ask Hermes for a pairing link from a device you're already signed in on. Open it on this phone, or paste it here. The link works once and expires in minutes.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://…/pair#…", text: $pastedText, axis: .vertical)
                .lineLimit(2...5)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .padding(12)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("fleet.pairing.field")

            HStack(spacing: FleetTheme.spacingMd) {
                #if canImport(UIKit)
                Button {
                    if let text = UIPasteboard.general.string { pastedText = text }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.pairing.paste")
                #endif
                if allowsScan {
                    Button { isShowingScanner = true } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("fleet.pairing.scan")
                }
            }

            Button {
                coordinator.receive(text: pastedText)
                pastedText = ""
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(theme.onHighlight)
            .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("fleet.pairing.continue")

            Text("Prefer to type the address and sign-in yourself? Close this and use Add Gateway.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: Progress

    private func progress(_ title: String, detail: String) -> some View {
        VStack(spacing: FleetTheme.spacingLg) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FleetTheme.spacingXl)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.pairing.progress")
    }

    // MARK: Confirmation

    private func confirmation(_ preview: PairingPreview) -> some View {
        let address = Self.address(of: preview.gateway.origin)
        return VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Text("Add this gateway?")
                    .font(.headline)
                    .foregroundStyle(theme.textSecondary)
                Text(preview.gateway.displayName)
                    .font(FleetTheme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("fleet.pairing.confirm.name")
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("fleet.pairing.confirm.address")
                if !preview.label.isEmpty {
                    Text("Link name: \(preview.label)")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Text("This phone will be allowed to")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                ForEach(preview.access, id: \.scope) { access in
                    Label {
                        Text(access.summary)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "key.fill").foregroundStyle(theme.highlight)
                    }
                    .accessibilityIdentifier("fleet.pairing.confirm.access")
                }
            }

            Text("Only continue if you expected this link and the address above is your gateway. The gateway will give this phone its own credential, kept in Keychain, which you can revoke on the gateway at any time.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: FleetTheme.spacingMd) {
                Button {
                    coordinator.confirm()
                } label: {
                    Text("Add to Fleet").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(theme.onHighlight)
                .accessibilityIdentifier("fleet.pairing.confirm")

                Button("Cancel", role: .cancel) { close() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("fleet.pairing.cancel")
            }
        }
    }

    // MARK: Outcomes

    private func outcome(symbol: String, tint: Color, title: String, message: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.pairing.\(id)")
            Text(message)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { close() } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(theme.onHighlight)
            .accessibilityIdentifier("fleet.pairing.done")
        }
    }

    private func failed(_ failure: PairingFailure, host: String?) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(FleetTheme.statusDestructive)
                .accessibilityHidden(true)
            Text(PairingCopy.title(for: failure))
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.pairing.failure.title")
            Text(PairingCopy.message(for: failure, host: host))
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.pairing.failure.message")
            if failure.isRetryable {
                Button {
                    coordinator.retry()
                } label: {
                    Text("Try Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(theme.onHighlight)
                .accessibilityIdentifier("fleet.pairing.retry")
            }
            Button("Close") { close() }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("fleet.pairing.failure.close")
        }
    }

    /// `host` or `host:port`, exactly what will be contacted.
    static func address(of origin: URL) -> String {
        guard let host = origin.host else { return origin.absoluteString }
        if let port = origin.port, port != 443 { return "\(host):\(port)" }
        return host
    }
}

/// Presents the pairing flow for a link that arrived from outside the app, at the root of the
/// app. Waits until the app is unlocked and the registry has loaded (a link that opens the app
/// cold must not show gateway identity over the lock screen or race hydration), and gives any
/// sheet already on screen a moment to go away first.
struct PairingLinkPresenter: ViewModifier {
    @Bindable var coordinator: PairingCoordinator
    let isReady: Bool
    @State private var showing = false
    /// The flow this sheet was shown for. A sheet's `onDismiss` runs after its dismiss animation;
    /// if a NEW link arrived meanwhile, that late callback must not cancel the new flow.
    @State private var presentedFlow: Int?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showing, onDismiss: {
                if presentedFlow == coordinator.flowID { coordinator.dismiss() }
                presentedFlow = nil
            }) {
                PairingSheet(coordinator: coordinator) { _ in
                    showing = false
                }
            }
            .task(id: wantsPresentation) {
                // Let a sheet that is already up (Add Gateway, say) finish dismissing.
                if wantsPresentation { try? await Task.sleep(for: .milliseconds(450)) }
                if wantsPresentation { presentedFlow = coordinator.flowID }
                showing = wantsPresentation
            }
            // A different link replacing the one on screen keeps the sheet up for the new flow.
            .onChange(of: coordinator.flowID) { _, newFlow in
                if showing { presentedFlow = newFlow }
            }
    }

    private var wantsPresentation: Bool {
        PairingPresentationPolicy.shouldPresentAtRoot(
            isReady: isReady, entry: coordinator.entry, isActive: coordinator.isActive)
    }
}

/// When the root presents the Add to Fleet screen. Separate and pure so cold-launch and
/// already-running behavior is testable without a UI.
enum PairingPresentationPolicy {
    /// Only a flow that started from a link (not from the Add Gateway form's own entry) is
    /// presented at the root, and only once the app is unlocked and the registry has loaded.
    /// Until then the link is held (previewing is non-destructive) and shown when ready.
    static func shouldPresentAtRoot(isReady: Bool, entry: PairingCoordinator.Entry, isActive: Bool) -> Bool {
        isReady && entry == .link && isActive
    }
}

extension View {
    /// Shows the Add to Fleet flow for links opened from outside the app.
    func pairingLinkPresenter(_ coordinator: PairingCoordinator, isReady: Bool) -> some View {
        modifier(PairingLinkPresenter(coordinator: coordinator, isReady: isReady))
    }
}
