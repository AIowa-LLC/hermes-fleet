import SwiftUI
import FleetCore

/// Bots on a specific gateway (U1 navigation skeleton).
///
/// Reads the union roster snapshot from `AppEnvironment` and lists the bots
/// owned by the selected gateway (fail closed: empty while the gateway is
/// unreachable — spec §31 partial availability). Tapping a bot drills into
/// its Sessions. U1 scope: NO bot-detail content (that's U2).
public struct BotsView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID

    public init(environment: AppEnvironment, gatewayID: GatewayID) {
        self.environment = environment
        self.gatewayID = gatewayID
    }

    public var body: some View {
        let bots = environment.bots(on: gatewayID)
        Group {
            if bots.isEmpty {
                emptyState
            } else {
                botList(bots)
            }
        }
        .navigationTitle(gatewayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await environment.refreshRoster() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.bots")
    }

    private var gatewayName: String {
        environment.gateway(for: gatewayID)?.displayName ?? gatewayID.rawValue
    }

    private func botList(_ bots: [FleetBot]) -> some View {
        List(bots) { bot in
            NavigationLink(value: FleetScreen.sessions(bot.route)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(bot.route.id)
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .monospaced()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fleet.bots.row.\(bot.route.id)")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
        .accessibilityIdentifier("fleet.bots.list")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Bots")
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(FleetTheme.accent)
            }
        } description: {
            Text("No profiles reported for this gateway. Connect and refresh the roster.")
        }
        .accessibilityIdentifier("fleet.bots.empty")
    }
}
