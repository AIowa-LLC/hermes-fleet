import SwiftUI
import SafariServices

/// "Support the Project" (refinement Phase 1): one neutral entry that opens
/// the project's public support page in an in-app Safari view. The app carries
/// no purchase, unlock, or amount language — the page holds the details.
public enum FleetSupportLink {
    /// Public support page on the project's official subdomain.
    public static let url = URL(string: "https://hermes-fleet.aiowa.dev/support")!
    public static let title = "Support the Project"
    public static let systemImage = "heart"
}

/// A row that presents `FleetSupportLink.url` in `SFSafariViewController`.
/// Used by both About and Settings so the copy and target cannot drift.
struct FleetSupportLinkRow: View {
    @Environment(\.fleetTheme) private var theme
    @State private var presenting = false
    let identifier: String

    var body: some View {
        Button {
            presenting = true
        } label: {
            Label {
                Text(FleetSupportLink.title)
                    .foregroundStyle(theme.textPrimary)
            } icon: {
                Image(systemName: FleetSupportLink.systemImage)
                    .foregroundStyle(theme.highlight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $presenting) {
            FleetSafariView(url: FleetSupportLink.url)
                .ignoresSafeArea()
        }
    }
}

/// Minimal `SFSafariViewController` host.
struct FleetSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
