import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// C2 — Settings-hosted sheet for the versioned agent setup prompt.
///
/// The DOOR: after the navigation rebuild the onboarding screen was only
/// reachable from the empty-gateways state, so any user with a configured
/// gateway could never get back to the setup prompt. This sheet is the
/// always-reachable door — presented from Settings ▸ Agent Setup Prompt —
/// and reuses the same `OnboardingPrompt` artifact and copy semantics as
/// `GatewayOnboardingView` (single source, no forked copy).
///
/// HIG-native: standard sheet presentation, Form/Section grouping, plain
/// system typography, `ShareLink` for the share path. No bespoke skin.
///
/// SECURITY: this view never renders secret material — the prompt itself is
/// parameterized and carries no credentials (see `OnboardingPrompt`).
public struct SetupPromptSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Bounded clipboard-confirmation (auto-clears so a stale "Copied" badge
    /// never lingers — same pattern as GatewayOnboardingView).
    @State private var copyConfirmed = false

    /// Collapsible full-prompt preview (off by default — copy/share are the
    /// primary paths; the preview is for review before sending).
    @State private var isShowingPrompt = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                copySection
                previewSection
            }
            .navigationTitle("Agent Setup Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("fleet.setup-prompt.close")
                }
            }
        }
        .accessibilityIdentifier("fleet.setup-prompt.sheet")
    }

    // MARK: Sections

    private var copySection: some View {
        Section {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("Send this prompt to your Hermes agent and it will set up the gateway end-to-end — network path, a scoped credential, and verification — then reply with the three values to add in the app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copyPrompt()
                } label: {
                    Label(
                        copyConfirmed ? "Copied — paste it in chat" : "Copy setup prompt",
                        systemImage: copyConfirmed ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(copyConfirmed)
                .accessibilityLabel(copyConfirmed ? "Prompt copied" : "Copy setup prompt")
                .accessibilityIdentifier("fleet.setup-prompt.copy")

                ShareLink(
                    item: OnboardingPrompt.text,
                    subject: Text("Hermes Fleet — agent setup prompt")
                ) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.setup-prompt.share")

                Button {
                    withAnimation { isShowingPrompt.toggle() }
                } label: {
                    Label(
                        isShowingPrompt ? "Hide prompt text" : "Review prompt text",
                        systemImage: isShowingPrompt ? "chevron.up" : "text.quote"
                    )
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("fleet.setup-prompt.toggle-prompt")
            }
            .listRowBackground(Color.clear)
        } footer: {
            Text("v\(OnboardingPrompt.version) — no secrets inside; your agent fills in the real values.")
        }
    }

    private var previewSection: some View {
        Group {
            if isShowingPrompt {
                Section {
                    Text(OnboardingPrompt.text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.setup-prompt.prompt-text")
                } header: {
                    Text("The prompt you'll send")
                }
            }
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

#if DEBUG
#Preview("Setup Prompt") {
    SetupPromptSheet()
}
#endif
