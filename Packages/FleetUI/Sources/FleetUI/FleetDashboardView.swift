import SwiftUI
import FleetCore

/// Fleet dashboard — the product's conceptual home.
///
/// M0 renders the empty state only (no gateways configured), matching the
/// product spec's fleet-first mental model. Loading/error and live fleet states
/// land in later milestones. Accessibility identifiers and labels are
/// first-class from day one.
///
/// M14: themed with FleetTheme (Black/White/Signal Red). The empty state stays
/// a native `ContentUnavailableView` — the SF Symbol is the functional glyph,
/// tinted Signal Red; text color is left to the system styles so Dynamic Type
/// and light/dark appearance continue to "just work". No generated UI.
public struct FleetDashboardView: View {
    private let gateways: [FleetGateway]

    public init(gateways: [FleetGateway]) {
        self.gateways = gateways
    }

    public var body: some View {
        Group {
            if gateways.isEmpty {
                emptyState
            } else {
                gatewayList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.dashboard")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Gateways")
            } icon: {
                Image(systemName: "server.rack")
                    .foregroundStyle(FleetTheme.accent)
            }
        } description: {
            Text("Add your first Hermes gateway to see your fleet.")
        }
        .accessibilityIdentifier("fleet.dashboard.empty")
    }

    private var gatewayList: some View {
        List(gateways) { gateway in
            Label(gateway.displayName, systemImage: "server.rack")
                .accessibilityLabel("Gateway \(gateway.displayName)")
        }
        .accessibilityIdentifier("fleet.dashboard.list")
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
    }
}

#if DEBUG
#Preview("Empty fleet") {
    FleetDashboardView(gateways: [])
}
#Preview("Empty fleet — dark") {
    FleetDashboardView(gateways: [])
        .preferredColorScheme(.dark)
}
#endif
