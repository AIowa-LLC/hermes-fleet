import SwiftUI
import FleetCore

/// Gateways list — the U1 cockpit root.
///
/// Reads the registered gateways from `AppEnvironment` (observable) and
/// exposes the runtime-owned connection lifecycle inline: each row shows the
/// §13 connection state and offers connect / disconnect / reconnect. Tapping
/// a row drills into that gateway's Bots.
///
/// M14 theme: Black/White/Signal Red; status is icon + text (color is
/// reinforcement only), per the semantic status map.
public struct GatewaysView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                emptyState
            } else {
                gatewayList
            }
        }
        .navigationTitle("Hermes Fleet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await environment.refreshRoster() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("fleet.gateways.refresh")
                .disabled(environment.isRefreshing)
            }
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.gateways")
    }

    // MARK: States

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
        .accessibilityIdentifier("fleet.gateways.empty")
    }

    private var gatewayList: some View {
        List(environment.gateways) { gateway in
            NavigationLink(value: FleetScreen.bots(gateway.id)) {
                GatewayRowView(environment: environment, gateway: gateway)
            }
            .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue)")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
        .accessibilityIdentifier("fleet.gateways.list")
    }
}

/// One gateway row: identity + connection lifecycle (observable) + the
/// runtime's connect/disconnect/reconnect actions.
private struct GatewayRowView: View {
    private let environment: AppEnvironment
    private let gateway: FleetGateway

    init(environment: AppEnvironment, gateway: FleetGateway) {
        self.environment = environment
        self.gateway = gateway
    }

    var body: some View {
        let state = environment.connectionStates[gateway.id] ?? .idle
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                Text(gateway.id.rawValue)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .monospaced()
            }

            Spacer()

            ConnectionStateBadge(state: state)
                .accessibilityElement(children: .combine)

            Menu {
                Button {
                    Task { await environment.connect(to: gateway.id) }
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                Button {
                    Task { await environment.disconnect(from: gateway.id) }
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
                Button {
                    Task { await environment.reconnect(to: gateway.id) }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue).menu")
        }
        .padding(.vertical, 2)
    }
}

/// The §13 semantic status badge: icon + text, color as reinforcement only.
private struct ConnectionStateBadge: View {
    let state: GatewayConnectionState

    var body: some View {
        Label {
            Text(label)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let status): return statusText(status)
        }
    }

    private var symbol: String {
        switch state {
        case .idle: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "wifi.slash"
        case .failed(let status):
            switch status {
            case .authenticationRequired: return "exclamationmark.circle.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .unsupported: return "xmark.octagon.fill"
            case .offline: return "wifi.slash"
            case .online, .connecting: return "circle"
            }
        }
    }

    private var color: Color {
        switch state {
        case .failed(let status):
            switch status {
            case .authenticationRequired, .degraded, .unsupported:
                return FleetTheme.accent
            case .offline, .online, .connecting:
                return FleetTheme.textSecondary
            }
        case .idle, .connecting, .connected, .disconnected:
            return FleetTheme.textSecondary
        }
    }

    private func statusText(_ status: GatewayStatus) -> String {
        switch status {
        case .online: return "Online"
        case .connecting: return "Connecting…"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Auth Required"
        case .offline: return "Unreachable"
        case .unsupported: return "Unsupported"
        }
    }
}
