import SwiftUI
import FleetCore

/// Build 41 — the Kanban tab root: gateway/board provenance chooser.
///
/// Fleet is multi-gateway; Kanban needs explicit provenance. One gateway →
/// open its board directly (no gate). Multiple gateways → an explicit
/// selector that remembers the last valid choice per device. Gateways
/// without kanban support render honestly as unsupported (fail closed).
public struct KanbanHomeView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                ContentUnavailableView {
                    Label("No gateways", systemImage: "server.rack")
                } description: {
                    Text("Register a Hermes gateway to work its Kanban board.")
                }
                .accessibilityIdentifier("kanban.home.empty")
            } else if environment.gateways.count == 1, let only = environment.gateways.first {
                KanbanBoardView(environment: environment, gatewayID: only.id)
            } else {
                gatewayList
            }
        }
        .navigationTitle("Kanban")
    }

    /// Explicit chooser (multi-gateway fleets).
    private var gatewayList: some View {
        List {
            Section {
                ForEach(environment.gateways) { gateway in
                    NavigationLink(value: FleetScreen.gatewayKanban(gateway.id)) {
                        HStack {
                            Label(gateway.displayName, systemImage: "server.rack")
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("fleet.kanban.gateway.\(gateway.id.rawValue)")
                }
            } footer: {
                Text("Each gateway serves its own boards. Your selection is remembered per device.")
            }
        }
    }
}
