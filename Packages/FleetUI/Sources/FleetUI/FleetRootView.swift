import SwiftUI

/// Root navigation shell (composition/navigation seam).
///
/// M0: a NavigationStack hosting the fleet dashboard. The concrete app target
/// (`HermesFleetApp`) owns the model instance and injects it here. This is the
/// only place SwiftUI composes app-wide navigation in M0.
///
/// M14: applies the Black/White/Signal Red design system — the whole stack is
/// tinted with the Signal Red accent and rides on the themed background.
public struct FleetRootView: View {
    private let model: FleetDashboardModel

    public init(model: FleetDashboardModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            FleetDashboardView(gateways: model.gateways)
                .navigationTitle("Hermes Fleet")
        }
        .tint(FleetTheme.accent)
    }
}
