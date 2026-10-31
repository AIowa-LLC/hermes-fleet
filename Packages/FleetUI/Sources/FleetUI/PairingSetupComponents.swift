import SwiftUI
import UIKit
import FleetCore

/// LEGACY (v1 connector, Telegram-only): the single maintained "message to Hermes". It is
/// shown only under "Other ways to connect" on BOTH the first-run screen and the
/// additional-server sheet; the default path is `/fleet pair` (docs/universal-login.md).
/// Do not duplicate this text.
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

/// "Message to Hermes" card for the legacy v1 connector: the shared prompt text plus a Copy
/// action. `idPrefix` keeps the accessibility identifiers of each host screen stable
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
                Text("Older Hermes connector (Telegram)")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                Text("Only for servers still on the first connector release, which can't make a /fleet pair link.")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Where a pasted link comes from. Reads the pasteboard only when called (on a tap), never
/// in the background; simulator UI tests can supply the text through a DEBUG-only hook.
enum PairingPasteboard {
    static func text() -> String? {
        #if DEBUG && targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["HERMES_FLEET_PAIRING_SIMULATED_PASTE"] {
            return simulated
        }
        #endif
        return UIPasteboard.general.string
    }
}

/// The default "Connect to Hermes" content shared by first-run and the add-server sheet: the
/// three steps and the two ways to hand the link to the app.
struct PairingConnectContent: View {
    @Environment(\.fleetTheme) private var theme
    let pairing: PairingCoordinator
    let idPrefix: String
    @Binding var presented: PairingScanSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
            steps
            actions
        }
    }

    private var steps: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                stepRow(1, "Ask Hermes for a link: send `/fleet pair` in any chat with Hermes, or run `hermes fleet pair` on your computer.")
                stepRow(2, "Open the link on this iPhone, or scan its QR code.")
                stepRow(3, "Approve the code Fleet shows.")
            }
        }
    }

    private func stepRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(theme.highlight)
                .frame(width: 24, height: 24)
                .background(theme.highlight.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(Self.plain(number))")
        .accessibilityIdentifier("\(idPrefix).step.\(number)")
    }

    /// VoiceOver reads the step without Markdown punctuation.
    private static func plain(_ number: Int) -> String {
        switch number {
        case 1: return "Ask Hermes for a link: send /fleet pair in any chat with Hermes, or run hermes fleet pair on your computer."
        case 2: return "Open the link on this iPhone, or scan its QR code."
        default: return "Approve the code Fleet shows."
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            Button {
                presented = .scanner
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .foregroundStyle(theme.onHighlight)
            .disabled(!pairing.isAvailable || pairing.isBusy)
            .accessibilityIdentifier("\(idPrefix).scan")

            Button {
                // Read the pasteboard only now, on the person's tap.
                pairing.receive(text: PairingPasteboard.text() ?? "")
                presented = .review
            } label: {
                Label("Paste link", systemImage: "doc.on.clipboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!pairing.isAvailable || pairing.isBusy)
            .accessibilityIdentifier("\(idPrefix).paste")

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

/// "Other ways to connect": the existing owner sign-in, manual setup and the legacy
/// (v1, Telegram) setup message. Secondary on purpose.
struct PairingOtherWaysPage: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    let idPrefix: String
    /// Closes the whole add-server surface (shown as a trailing Cancel); nil on first-run.
    let onCancel: (() -> Void)?

    @State private var showsOwnerSignIn = false
    @State private var showsManualForm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                Text("Use these only if a Hermes link doesn\u{2019}t fit your server.")
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
                .accessibilityIdentifier("\(idPrefix).advanced.owner")
                Button {
                    environment.gatewayFormDraft.begin(pendingSheet: .add, initial: nil)
                    showsManualForm = true
                } label: {
                    Label("Enter gateway details manually", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(idPrefix).advanced.manual")
                PairingSetupPromptCard(idPrefix: "\(idPrefix).legacy", showsFullMessage: false)
            }
            .padding(FleetTheme.spacingXl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Other ways to connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("\(idPrefix).advanced.cancel")
                }
            }
        }
        .sheet(isPresented: $showsOwnerSignIn) {
            GatewayOnboardingView(environment: environment, canDismiss: true)
        }
        .sheet(isPresented: $showsManualForm) {
            GatewayFormSheet(
                title: "Advanced Gateway Setup",
                saveButton: "Add",
                initial: nil,
                draftStore: environment.gatewayFormDraft,
                onInvitation: { _ = environment.pairing.receive(text: $0, entry: .link) },
                reviewKey: { try await environment.reviewTLSKey(for: $0) }
            ) { registration, credential, tlsReview in
                _ = try await environment.addGateway(
                    registration,
                    credential: credential,
                    tlsReview: tlsReview)
            }
        }
        .onAppear {
            // A manual form can outlive this view's @State during the Face ID
            // lock teardown; restore only that presentation (never credentials).
            if environment.gatewayFormDraft.pendingSheet == .add { showsManualForm = true }
        }
    }
}

/// The entry row to "Other ways to connect".
struct PairingOtherWaysEntry: View {
    let idPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Other ways to connect", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("\(idPrefix).advanced")
    }
}

/// Presents the scanner, then the review sheet once the camera sheet is gone, and handles
/// links that arrive from outside the app while this screen is showing. Backing out of an
/// un-redeemed invitation when the app is backgrounded, but only pausing a waiting approval.
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
                switch phase {
                case .background:
                    pairing.appMovedToBackground()
                    if !pairing.isActive { presented = nil }
                case .active:
                    pairing.appBecameActive()
                default:
                    break
                }
            }
            .onChange(of: pairing.isActive) { _, active in
                if !active { presented = nil }
            }
            .onChange(of: pairing.flowID) { _, _ in presentIncomingLink() }
            .onAppear {
                pairing.registerPresenter()
                presentIncomingLink()
            }
            .onDisappear { pairing.unregisterPresenter() }
    }

    private func sheetDidDismiss() {
        // The scanner hands the raw link to the coordinator and dismisses
        // itself. Present the preview only after the camera sheet is gone.
        if pairing.isActive { presented = .review }
    }

    /// A link opened from outside the app (tap, QR scanned in Camera) shows its review here.
    private func presentIncomingLink() {
        guard pairing.isActive, pairing.entry == .link, presented != .review else { return }
        presented = .review
    }
}

extension View {
    func pairingScanSheets(pairing: PairingCoordinator, presented: Binding<PairingScanSheet?>) -> some View {
        modifier(PairingScanSheets(pairing: pairing, presented: presented))
    }

    /// App-level presenter for links that arrive while no add-server screen is showing (the
    /// person is using the tabs). Add-server screens present their own flow.
    func pairingLinkPresenter(_ pairing: PairingCoordinator) -> some View {
        modifier(PairingLinkPresenter(pairing: pairing))
    }
}

struct PairingLinkPresenter: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var pairing: PairingCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { pairing.isActive && pairing.entry == .link && !pairing.hasInlinePresenter },
                set: { shown in if !shown, pairing.canCancel { pairing.dismiss() } }
            )) {
                PairingInvitationReviewSheet(coordinator: pairing)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: pairing.appMovedToBackground()
                case .active: pairing.appBecameActive()
                default: break
                }
            }
    }
}
