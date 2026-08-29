import SwiftUI
import FleetCore

/// Fleet dashboard — the product's conceptual home.
///
/// M0 renders the empty state only (no gateways configured), matching the
/// product spec's fleet-first mental model. Loading/error and live fleet states
/// land in later milestones. Accessibility identifiers and labels are
/// first-class from day one.
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
        .accessibilityIdentifier("fleet.dashboard")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Gateways",
            systemImage: "server.rack",
            description: Text("Add your first Hermes gateway to see your fleet.")
        )
        .accessibilityIdentifier("fleet.dashboard.empty")
    }

    private var gatewayList: some View {
        List(gateways) { gateway in
            Label(gateway.displayName, systemImage: "server.rack")
                .accessibilityLabel("Gateway \(gateway.displayName)")
        }
        .accessibilityIdentifier("fleet.dashboard.list")
    }
}

#if DEBUG
#Preview("Empty fleet") {
    FleetDashboardView(gateways: [])
}
#endif
