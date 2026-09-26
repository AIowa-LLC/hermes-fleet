import SwiftUI

/// ADR-0011: the official legal/hosting surface for Hermes Fleet. Terms of
/// Use and the Privacy Policy are published at the AIowa subdomain; the
/// repository files (`TERMS.md` / `PRIVACY.md`) remain the source of truth
/// for content, and the App Store Connect `privacyPolicyUrl` metadata field
/// points at the same privacy URL. Support stays the public issue tracker.
public enum FleetLegal {
    /// Official subdomain hosting the published policy documents.
    public static let baseURL = URL(string: "https://hermes-fleet.aiowa.dev")!

    /// Terms of Use (Apple's Standard EULA remains the app license; this
    /// document governs service behavior — ADR-0011 decision 2).
    public static let termsURL = URL(string: "https://hermes-fleet.aiowa.dev/terms")!

    /// Privacy Policy (App Review Guideline 5.1.1(i) — linked in-app here
    /// AND in the App Store Connect metadata field).
    public static let privacyPolicyURL = URL(string: "https://hermes-fleet.aiowa.dev/privacy")!

    /// Public support channel (unchanged target).
    public static let supportURL = URL(string: "https://github.com/AIowa-LLC/hermes-fleet/issues")!
}

/// ADR-0011: About is a first-class tab carrying app identity, the
/// version/build row, and the legal + support links. The retired Settings
/// rows (`fleet.settings.version` / `privacy-policy` / `support`) live here
/// as `fleet.about.*`.
public struct FleetAboutView: View {
    @Environment(\.fleetTheme) private var theme

    public init() {}

    public var body: some View {
        Form {
            Section {
                HStack(spacing: FleetTheme.spacingMd) {
                    Image(systemName: "square.grid.2x2")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(theme.highlight)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                        Text("Hermes Fleet")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                        Text("A pocket operations console for your agents.")
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("fleet.about.identity")
            }

            Section {
                LabeledContent("Version", value: Self.appVersion)
                    .accessibilityIdentifier("fleet.about.version")
            } header: {
                Text("Version")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                Link(destination: FleetLegal.termsURL) {
                    Label("Terms of Use", systemImage: "doc.text")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.about.terms")
                Link(destination: FleetLegal.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.about.privacy-policy")
                Link(destination: FleetLegal.supportURL) {
                    Label("Support", systemImage: "questionmark.circle")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.about.support")
            } header: {
                Text("Legal")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Hermes Fleet connects directly to gateways you choose. "
                     + "Review the policy before pairing a gateway.")
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.highlight)
        .navigationTitle("About")
        .accessibilityIdentifier("fleet.about")
    }

    /// Marketing/build version from the main bundle (no invented values).
    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build { return "\(short) (\(build))" }
        if let short { return short }
        return "Unknown"
    }
}

#if DEBUG
#Preview("About") {
    NavigationStack {
        FleetAboutView()
    }
    .preferredColorScheme(.dark)
}
#endif
