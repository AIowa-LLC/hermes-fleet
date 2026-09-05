import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// F3 — onboarding sheet for brand-new users (no gateway configured).
///
/// One tap copies the versioned `OnboardingPrompt` to the clipboard; the
/// user pastes it into their Hermes chat (Telegram etc.), their own agent
/// executes the mission (install / network / credential / verify), and the
/// user returns here to hand-enter the returned URL / username / password
/// into the existing Add-Gateway flow.
///
/// UX direction (apple-design): a big primary copy button with visible
/// confirmation, a collapsible read-only prompt preview (selected-by-default
/// so manual copy is one gesture), a paste-friendly "result" guidance screen,
/// and a docs link (cyan link token — U2 semantic). QR entry (F2) is
/// referenced from the Add-Gateway form, not duplicated here (out of scope).
///
/// SECURITY: this view never renders secret material. The only credential
/// surface is the existing Add-Gateway form; the onboarding step text names
/// the fields but stores nothing.
public struct GatewayOnboardingView: View {

    /// What the agent's reply asks the user to do next, per mission leg.
    private enum Step: Int, CaseIterable, Identifiable {
        case install
        case network
        case credentials
        case enter

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .install: return "Copy the prompt"
            case .network: return "Send it to your agent"
            case .credentials: return "Agent replies with values"
            case .enter: return "Enter them in Add Gateway"
            }
        }

        var detail: String {
            switch self {
            case .install:
                return "Tap Copy, then paste the message into your Hermes chat (Telegram, etc.)."
            case .network:
                return "Your agent verifies the network path and the gateway, and mints a scoped app credential."
            case .credentials:
                return "It replies with exactly the URL, username, and password to use — nothing else needed."
            case .enter:
                return "Come back here, open Add Gateway, and enter the three values. A QR scan works too (F2)."
            }
        }

        var symbol: String {
            switch self {
            case .install: return "doc.on.doc"
            case .network: return "paperplane.fill"
            case .credentials: return "key.fill"
            case .enter: return "square.and.pencil"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Bounded clipboard-confirmation (auto-clears so a stale "Copied" badge
    /// never lingers into a later session).
    @State private var copyConfirmed = false

    /// Collapsible full-prompt preview (off by default — the big copy button
    /// is the primary path; the preview is for review before copying).
    @State private var isShowingPrompt = false

    /// Injected by `GatewaysView`: opens the existing Add-Gateway sheet,
    /// beginning a root-owned draft (the returned URL/username/password land
    /// in the SAME Keychain-backed flow as manual entry — no parallel path).
    /// The parent swaps its presented sheet, which dismisses this one.
    private let onEnterValues: () -> Void

    public init(onEnterValues: @escaping () -> Void) {
        self.onEnterValues = onEnterValues
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FleetTheme.spacingXl) {
                    header
                    copySection
                    stepsSection
                    promptPreviewSection
                    docsSection
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(FleetTheme.background.ignoresSafeArea())
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("fleet.onboarding.close")
                }
            }
        }
        .tint(FleetTheme.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 40))
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)
            Text("Hermes Fleet")
                .font(FleetTheme.titleFont)
                .foregroundStyle(FleetTheme.accent)
                .accessibilityIdentifier("fleet.onboarding.title")
            Text("No gateways yet. Your own Hermes agent can set everything up — the app, the network path, and a scoped gateway credential — and hand you three values to type in.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
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
                }
                .buttonStyle(.borderedProminent)
                .disabled(copyConfirmed)
                .accessibilityLabel(copyConfirmed ? "Prompt copied" : "Copy setup prompt")
                .accessibilityIdentifier("fleet.onboarding.copy")

                if copyConfirmed {
                    Text("Copied to your clipboard. The confirmation clears in a few seconds.")
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
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
                .foregroundStyle(FleetTheme.accent)
                .accessibilityIdentifier("fleet.onboarding.toggle-prompt")
            }
        }
    }

    private var stepsSection: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                Text("How it works")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    ForEach(Array(Step.allCases.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
                            Image(systemName: step.symbol)
                                .font(.body)
                                .foregroundStyle(FleetTheme.accent)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(step.title)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(FleetTheme.textPrimary)
                                Text(step.detail)
                                    .font(FleetTheme.secondaryFont)
                                    .foregroundStyle(FleetTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Button {
                    onEnterValues()
                } label: {
                    Label("I have the values — Add Gateway", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.onboarding.enter-values")
            }
        }
    }

    /// Paste-friendly result guidance: what the agent's reply looks like and
    /// where each value goes. Rendered as selectable plain text (NOT a Form
    /// with fields) so the user can long-press-copy from the chat side.
    private var promptPreviewSection: some View {
        Group {
            if isShowingPrompt {
                FleetCard {
                    VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                        Text("The prompt you'll send")
                            .font(FleetTheme.sectionHeaderFont)
                            .foregroundStyle(FleetTheme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text(OnboardingPrompt.text)
                            .font(.callout.monospaced())
                            .foregroundStyle(FleetTheme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fleet.onboarding.prompt-text")
                        Text("v\(OnboardingPrompt.version) — no secrets inside; your agent fills in the real values.")
                            .font(.caption)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
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
            .foregroundStyle(FleetTheme.accent)
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

/// F3 — docs links (single source; the docs URL moves with the site).
public enum OnboardingDocs {
    /// Hermes Agent docs — the authoritative always-current reference.
    public static let bootstrapURL = URL(string: "https://hermes-agent.nousresearch.com/docs")!
}
