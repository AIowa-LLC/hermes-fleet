import SwiftUI

/// Refinement Phase 4 — the first-run trust statement: open source, your
/// servers, no account, no middleman.
///
/// Every line is a claim about current code, checked before it was written:
/// - the repository is public under the MIT license (`LICENSE`);
/// - pairing talks only to the server named in the link (`GatewayPairingClient`
///   refuses redirects and pins the server's key); owner sign-in posts to the
///   server's own `auth/password-login`;
/// - Fleet has no account system of its own;
/// - nothing sits between the phone and the server: there is no Fleet relay or
///   cloud service in the connection path (the push relay in `RelayKeyID` is a
///   design that nothing calls yet — revisit this copy if it ships).
struct OnboardingTrustPoints: View {
    struct Point: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
    }

    static let points: [Point] = [
        Point(id: "open-source", title: "Open source",
              detail: "MIT-licensed. Read every line.",
              systemImage: "chevron.left.forwardslash.chevron.right"),
        Point(id: "your-servers", title: "Your servers",
              detail: "Fleet connects only to Hermes servers you add.",
              systemImage: "server.rack"),
        Point(id: "no-account", title: "No account",
              detail: "Nothing to sign up for. There is no Fleet login.",
              systemImage: "person.crop.circle.badge.xmark"),
        Point(id: "no-middleman", title: "No middleman",
              detail: "No relay or cloud between your phone and your server.",
              systemImage: "arrow.left.arrow.right"),
    ]

    static let sourceURL = URL(string: "https://github.com/AIowa-LLC/hermes-fleet")!

    let idPrefix: String
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .topLeading)]
            : [GridItem(.flexible(), spacing: FleetTheme.spacingMd, alignment: .topLeading),
               GridItem(.flexible(), alignment: .topLeading)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: FleetTheme.spacingMd) {
                ForEach(Self.points) { point in
                    pointView(point)
                }
            }
            Link(destination: Self.sourceURL) {
                Label("View the source on GitHub", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(theme.highlight)
            .accessibilityIdentifier("\(idPrefix).trust.source")
        }
        // `.contain` keeps this identifier on the container; without it SwiftUI
        // pushes it down onto the children and the source link loses its own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix).trust")
    }

    private func pointView(_ point: Point) -> some View {
        HStack(alignment: .top, spacing: FleetTheme.spacingSm) {
            Image(systemName: point.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.highlight)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(point.detail)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(idPrefix).trust.\(point.id)")
    }
}
