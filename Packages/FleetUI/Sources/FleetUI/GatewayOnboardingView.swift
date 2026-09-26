import SwiftUI
import FleetCore
#if canImport(UIKit)
import UIKit
#endif

/// First-run setup experience — the root surface for a hydrated, ZERO-gateway
/// fleet (see `AppEnvironment.hydrationPhase` / `FleetTabView`).
///
/// The product model (borrowed from Hermex's lifecycle, not its copy): an
/// unconfigured app presents first-server setup BEFORE the normal tab UI;
/// once a gateway is registered the gate disappears because the registry is
/// no longer empty (the registry IS the onboarding state — no separate
/// hasSeenOnboarding flag).
///
/// One tap copies the versioned universal `OnboardingPrompt` for the user to
/// send to Hermes on ANY computer they want to control (macOS, Windows, or
/// Linux — the prompt tells that Hermes to detect its own environment).
/// Experienced users can skip straight into the REAL Add-Gateway form
/// (same draft + Keychain path as manual entry from the Gateways tab — no
/// duplicate registration implementation), which also hosts the QR pairing
/// scanner.
///
/// SECURITY: this view never renders secret material. The only credential
/// surface is the existing Add-Gateway form; nothing is stored here.
public struct GatewayOnboardingView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment

    /// What the user does after Hermes replies, per step.
    private enum Step: Int, CaseIterable, Identifiable {
        case copy
        case send
        case reply
        case enter

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .copy: return "Copy the setup prompt"
            case .send: return "Send it to Hermes"
            case .reply: return "Hermes replies with values"
            case .enter: return "Enter them in Add Gateway"
            }
        }

        var detail: String {
            switch self {
            case .copy:
                return "Tap Copy, then paste the message into a chat with Hermes on the computer you want to add."
            case .send:
                return "That Hermes inspects its machine, prepares its gateway connection, and picks a secure way for your phone to reach it."
            case .reply:
                return "It replies with exactly the URL, username, and password to use — nothing else needed."
            case .enter:
                return "Come back here, open Add Gateway, and enter the values. Scanning a pairing code works too."
            }
        }

        var symbol: String {
            switch self {
            case .copy: return "doc.on.doc"
            case .send: return "paperplane.fill"
            case .reply: return "key.fill"
            case .enter: return "square.and.pencil"
            }
        }
    }

    @Environment(\.openURL) private var openURL

    /// Bounded clipboard-confirmation (auto-clears so a stale "Copied" badge
    /// never lingers into a later session).
    @State private var copyConfirmed = false

    /// Collapsible full-prompt preview (off by default — the big copy button
    /// is the primary path; the preview is for review before copying).
    @State private var isShowingPrompt = false

    /// The REAL Add-Gateway sheet (same form the Gateways tab presents —
    /// draft store + Keychain-backed save seam; no parallel path).
    @State private var isShowingAddForm = false

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FleetTheme.spacingXl) {
                    header
                    copySection
                    stepsSection
                    docsSection
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // First-run has nothing to dismiss TO — the gate leaves only
                // by registering a gateway (or is never shown once one
                // exists). The placeholder keeps the nav bar balanced.
                ToolbarItem(placement: .cancellationAction) { Color.clear.frame(width: 0, height: 0) }
            }
        }
        .tint(theme.highlight)
        .preferredColorScheme(.dark)
        // The REAL Add-Gateway form: identical construction to the Gateways
        // tab's sheet (root-owned draft + the same registry/Keychain save
        // seam). A successful save flips hydrationPhase → configured and the
        // root gate swaps in the normal app — no extra transition needed.
        .sheet(isPresented: $isShowingAddForm) {
            GatewayFormSheet(
                title: "Add Gateway",
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
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 40))
                .foregroundStyle(theme.highlight)
                .accessibilityHidden(true)
            Text("Hermes Fleet")
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.highlight)
                .accessibilityIdentifier("fleet.onboarding.title")
            Text("Connect your first Hermes server")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.onboarding.headline")
            Text("Fleet connects your iPhone to Hermes running on your computers. Send a setup prompt to Hermes on the computer you want to add — it will inspect that machine, choose a supported secure connection method, and return the information Fleet needs.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var copySection: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                Button {
                    copyPrompt()
                } label: {
                    Label {
                        Text(copyConfirmed ? "Copied — paste it in chat" : "Copy setup prompt")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    } icon: {
                        Image(systemName: copyConfirmed ? "checkmark.circle.fill" : "doc.on.doc.fill")
                    }
                    // Ink on the WHOLE label (title AND glyph): this exists
                    // because borderedProminent's default ink is not legible
                    // on every highlight, and the Image never inherits a
                    // modifier applied to the Text alone. Same shape as
                    // SetupPromptSheet's copy control.
                    .foregroundStyle(theme.onHighlight)
                }
                .buttonStyle(.borderedProminent)
                .disabled(copyConfirmed)
                .accessibilityLabel(copyConfirmed ? "Prompt copied" : "Copy setup prompt")
                .accessibilityIdentifier("fleet.onboarding.copy")

                if copyConfirmed {
                    Text("Copied to your clipboard. The confirmation clears in a few seconds.")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .transition(.opacity)
                        .accessibilityIdentifier("fleet.onboarding.copy.confirmation")
                }

                Button {
                    withAnimation { isShowingPrompt.toggle() }
                } label: {
                    Label(
                        isShowingPrompt ? "Hide prompt text" : "Review prompt text",
                        systemImage: isShowingPrompt ? "chevron.up" : "text.quote"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.highlight)
                .accessibilityIdentifier("fleet.onboarding.toggle-prompt")

                // Build-88 dogfood fix: the preview renders INLINE, directly
                // under the toggle the user just tapped — it must be visible
                // where the interaction happened, never below the fold.
                // (The previous placement — a card inserted after the steps
                // section with a `.move(edge: .top)` transition — swept the
                // prompt down past the fold: the reported "flies across the
                // screen, then you have to scroll to see it".)
                if isShowingPrompt {
                    promptPreviewCard
                        .transition(.opacity)
                }
            }
        }
    }

    /// Paste-friendly prompt preview: rendered as selectable plain text so
    /// the user can long-press-copy from here as well. Rendered inline in
    /// `copySection` (right under the Review toggle) so opening it never
    /// moves the user's context; opening/closing never dismisses onboarding.
    private var promptPreviewCard: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("The prompt you'll send")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingPrompt.text)
                    .font(.callout.monospaced())
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.onboarding.prompt-text")
                Text("v\(OnboardingPrompt.version) — no secrets inside; your Hermes fills in the real values.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var stepsSection: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                Text("How it works")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    ForEach(Array(Step.allCases.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
                            Image(systemName: step.symbol)
                                .font(.body)
                                .foregroundStyle(theme.highlight)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(step.title)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Text(step.detail)
                                    .font(FleetTheme.secondaryFont)
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Button {
                    environment.gatewayFormDraft.begin(pendingSheet: .add, initial: nil)
                    isShowingAddForm = true
                } label: {
                    Label("I already have connection details", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.onboarding.enter-values")

                // Optional QR path: the pairing scanner lives inside the
                // same Add-Gateway form (one registration implementation —
                // this is a shortcut to its pairing section, not a fork).
                Button {
                    environment.gatewayFormDraft.begin(pendingSheet: .add, initial: nil)
                    isShowingAddForm = true
                } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.onboarding.scan")
            }
        }
    }

    private var docsSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Button {
                openURL(OnboardingDocs.bootstrapURL)
            } label: {
                Label("Read the setup guide", systemImage: "book")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.highlight)
            .accessibilityIdentifier("fleet.onboarding.docs")
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: Actions

    private func copyPrompt() {
        #if canImport(UIKit)
        UIPasteboard.general.string = OnboardingPrompt.text
        #endif
        withAnimation { copyConfirmed = true }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { copyConfirmed = false }
        }
    }
}

/// Docs links (single source; the docs URL moves with the site).
public enum OnboardingDocs {
    /// Hermes Agent docs — the authoritative always-current reference.
    public static let bootstrapURL = URL(string: "https://hermes-agent.nousresearch.com/docs")!
}
