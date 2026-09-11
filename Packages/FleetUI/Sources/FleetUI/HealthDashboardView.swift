import SwiftUI
import FleetCore

/// H2 Connection health dashboard — per-gateway connection health.
///
/// Renders one row per registered gateway with:
///   - current state (live observable connection lifecycle — online /
///     connecting / disconnected / failed)
///   - uptime % (accumulated connected / settled time, since first observed)
///   - reconnect count (re-establishments after the first connect)
///   - last disconnect reason (+ relative time)
///   - heartbeat ping RTT (last + average)
///
/// Data comes from `AppEnvironment.healthStats` (the FleetCore
/// `GatewayHealthStatsAccumulator` fed by the composition root) plus the live
/// observable `connectionStates`. A lightweight 1-second refresh loop keeps the
/// dashboard live while it is on screen; the accumulator keeps accumulating
/// regardless (fed by transport events for the app's lifetime).
///
/// M14 theme: Black/White/Signal Red; state is icon + text (color is
/// reinforcement only).
public struct HealthDashboardView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gatewayID: GatewayID?

    public init(environment: AppEnvironment, gatewayID: GatewayID? = nil) {
        self.environment = environment
        self.gatewayID = gatewayID
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                emptyState
            } else {
                gatewayList
            }
        }
        .navigationTitle("Connection Health")
        .background(theme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.health")
        .task {
            // Live refresh while the dashboard is visible. The accumulator is
            // fed by transport events independently, so this loop only copies
            // the latest snapshot into the observable state.
            while !Task.isCancelled {
                await environment.refreshHealthStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Gateways")
            } icon: {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(theme.highlight)
            }
        } description: {
            Text("Add a gateway to see its connection health.")
        }
        .accessibilityIdentifier("fleet.health.empty")
    }

    private var gatewayList: some View {
        List(environment.gateways.filter { gatewayID == nil || $0.id == gatewayID }) { gateway in
            HealthRowView(environment: environment, gateway: gateway)
                .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .accessibilityIdentifier("fleet.health.list")
    }
}

/// One gateway's connection-health row: identity + live state + the
/// accumulated stats (uptime %, reconnects, last disconnect, ping RTT).
private struct HealthRowView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gateway: FleetGateway

    init(environment: AppEnvironment, gateway: FleetGateway) {
        self.environment = environment
        self.gateway = gateway
    }

    var body: some View {
        let stats = environment.healthStats[gateway.id]
        let state = environment.connectionStates[gateway.id] ?? .idle

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(theme.highlight)
                    .accessibilityHidden(true)
                    .fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    Text(gateway.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(gateway.endpoint?.absoluteString ?? gateway.id.rawValue)
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HealthStateBadge(state: state)
                    .accessibilityElement(children: .combine)
                    .fixedSize()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                metricRow(label: "Uptime",
                          value: stats.map { Self.percent($0.uptimePercentage) } ?? "—",
                          identifier: "fleet.health.uptime.\(gateway.id.rawValue)")
                metricRow(label: "Reconnects",
                          value: stats.map { "\($0.reconnectCount)" } ?? "—",
                          identifier: "fleet.health.reconnects.\(gateway.id.rawValue)")
                metricRow(label: "Last disconnect",
                          value: lastDisconnectText(stats),
                          identifier: "fleet.health.last-disconnect.\(gateway.id.rawValue)")
                metricRow(label: "Ping RTT",
                          value: rttText(stats),
                          identifier: "fleet.health.rtt.\(gateway.id.rawValue)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.health.row.\(gateway.id.rawValue)")
    }

    /// V5 accessibility (t_b2628d33): metrics render via FleetMetadataRow —
    /// ONE combined VoiceOver element announcing "UPTIME: 99.9%" instead of
    /// two separate KEY / VALUE reads. The per-metric accessibilityIdentifier
    /// lives on the combined element. Values keep tabular figures (monospaced
    /// digits on the mono font).
    private func metricRow(label: String, value: String, identifier: String) -> some View {
        FleetMetadataRow(label, value, showDivider: false)
            .accessibilityIdentifier(identifier)
    }

    private func lastDisconnectText(_ stats: GatewayHealthStats?) -> String {
        guard let stats, let reason = stats.lastDisconnectReason else { return "—" }
        if let at = stats.lastDisconnectAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "\(reason) · \(formatter.localizedString(for: at, relativeTo: Date()))"
        }
        return reason
    }

    private func rttText(_ stats: GatewayHealthStats?) -> String {
        guard let stats, let last = stats.lastPingRTTMilliseconds else { return "—" }
        if stats.pingSampleCount > 1, let average = stats.averagePingRTTMilliseconds {
            return String(format: "%.0f ms · avg %.0f ms", last, average)
        }
        return String(format: "%.0f ms", last)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

/// The §13 semantic status badge for the health row (icon + text; color is
/// reinforcement only). Mirrors the Gateways row presentation.
private struct HealthStateBadge: View {
    @Environment(\.fleetTheme) private var theme
    let state: GatewayConnectionState

    var body: some View {
        Label {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
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
            case .authenticationRequired:
                return FleetTheme.statusNeedsIntervention
            case .degraded, .unsupported:
                return FleetTheme.statusDegraded
            case .offline, .online, .connecting:
                return theme.textSecondary
            }
        case .idle, .connecting, .connected, .disconnected:
            return theme.textSecondary
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
