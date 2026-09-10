import SwiftUI
import FleetCore
import FleetPersistence

/// Connection activity (Fleet section, reachable from Gateways → Connection
/// history and Fleet Home) — REAL connection activity, honestly scoped.
///
/// The fleet has no persistent event log yet (the gateway event stream exists
/// per-conversation, and connection-health accumulation is per-gateway). This
/// tab therefore renders what IS real today, from `AppEnvironment.healthStats`
/// (the H2 accumulator, persisted across launches):
///   - per-gateway connection events derived from the accumulated stats —
///     reconnects (count) and the last disconnect (reason + relative time);
///   - the live current state (from the observable connection lifecycle).
///
/// Honest gaps: no fabricated timeline entries. A gateway with no observed
/// stats renders an explicit "No connection activity recorded yet" row; an
/// empty fleet renders the empty state. When a persistent fleet-wide event
/// log lands, this view is the mount point (U4+).
public struct FleetActivityView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                emptyState
            } else {
                activityList
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            // H2 Connection health dashboard (per-gateway uptime / reconnects
            // / last-disconnect / ping RTT) — previously the Gateways toolbar
            // entry; Activity is its tab home under U3.
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: FleetScreen.health) {
                    Label("Health", systemImage: "heart.text.square")
                }
                .accessibilityIdentifier("fleet.activity.health")
            }
        }
        .background(theme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.activity")
        .task {
            // Copy the latest accumulated stats into the observable state on
            // entry (the accumulator is fed by the composition root's
            // transport feed regardless).
            await environment.refreshHealthStats()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Gateways")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(theme.highlight)
            }
        } description: {
            Text("Add a gateway to see its connection activity.")
        }
        .accessibilityIdentifier("fleet.activity.empty")
    }

    private var activityList: some View {
        List {
            ForEach(environment.gateways) { gateway in
                ActivityRowView(environment: environment, gateway: gateway)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .accessibilityIdentifier("fleet.activity.list")
    }
}

/// One gateway's real activity summary (nothing fabricated).
private struct ActivityRowView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gateway: FleetGateway
    @State private var now = Date()

    init(environment: AppEnvironment, gateway: FleetGateway) {
        self.environment = environment
        self.gateway = gateway
    }

    private var stats: GatewayHealthStats? {
        environment.healthStats[gateway.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            HStack(spacing: FleetTheme.spacingMd) {
                Text(gateway.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                StatusPill(status: liveStatus)
            }

            if let stats, isReal(stats) {
                activityLines(stats)
            } else {
                Text("No connection activity recorded yet.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, FleetTheme.spacingXs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.activity.row.\(gateway.id.rawValue)")
        .task {
            // Keep relative disconnect timestamps fresh while visible.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Live observable state (falls back to the persisted "last known").
    private var liveStatus: FleetStatus {
        if let state = environment.connectionStates[gateway.id] {
            switch state {
            case .connected: return .online
            case .connecting: return .waiting
            case .idle: return .unknown
            case .disconnected: return .offline
            case .failed(let status): return FleetStatus(gatewayStatus: status)
            }
        }
        return FleetStatus(gatewayStatus: stats?.currentState ?? .offline)
    }

    /// True when the accumulated stats carry at least one real observation
    /// (any reconnect, any disconnect, or any observed time) — a zeroed
    /// default `GatewayHealthStats` is "never observed", not "0 events".
    private func isReal(_ stats: GatewayHealthStats) -> Bool {
        stats.reconnectCount > 0
            || stats.lastDisconnectAt != nil
            || stats.connectedMilliseconds > 0
            || stats.disconnectedMilliseconds > 0
    }

    @ViewBuilder
    private func activityLines(_ stats: GatewayHealthStats) -> some View {
        if stats.reconnectCount > 0 {
            activityLine(
                icon: "arrow.triangle.2.circlepath",
                text: "\(stats.reconnectCount) reconnect\(stats.reconnectCount == 1 ? "" : "s")"
            )
        }
        if let at = stats.lastDisconnectAt, let reason = stats.lastDisconnectReason {
            activityLine(
                icon: "wifi.slash",
                text: "Last disconnect \(relativeTime(from: at)) — \(reason)"
            )
        } else if stats.lastDisconnectAt == nil && stats.connectedMilliseconds > 0 {
            activityLine(icon: "checkmark.circle", text: "Connected — no disconnects recorded")
        }
        if stats.pingSampleCount > 0, let rtt = stats.lastPingRTTMilliseconds {
            activityLine(
                icon: "waveform.path.ecg",
                text: String(format: "Ping %.0f ms", rtt)
            )
        }
    }

    private func activityLine(icon: String, text: String) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            // V3: reconnect/ping lines are telemetry — mono, terminal voice.
            Text(text)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

#if DEBUG
#Preview("Activity — empty fleet") {
    NavigationStack {
        FleetActivityView(
            environment: AppEnvironment(
                registry: NoopRegistry(),
                roster: NoopRoster(),
                cache: try! SwiftDataCacheStore.makeInMemory(),
                sessionList: NoopSessionList(),
                connectionFactory: { gateway, _ in NoopConnection(gatewayID: gateway.id) },
                health: NoopHealth()
            )
        )
    }
    .preferredColorScheme(.dark)
}

private struct NoopConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {}
    func disconnect() async {}
    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

struct NoopRegistry: GatewayRegistryManaging {
    func allGateways() async -> [FleetGateway] { [] }
    func gateway(for id: GatewayID) async -> FleetGateway? { nil }
    func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        FleetGateway(
            id: registration.id ?? GatewayID(rawValue: "preview-\(registration.displayName)"),
            displayName: registration.displayName,
            endpoint: registration.endpoint
        )
    }
    func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        FleetGateway(id: id, displayName: "preview", endpoint: nil)
    }
    func removeGateway(_ id: GatewayID) async throws {}
    func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
        GatewayTestResult(status: .offline)
    }
    func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
    func clearCredential(for id: GatewayID) async throws {}
    func hasCredential(for id: GatewayID) async -> Bool { false }
    func restorePersistedGateways() async throws -> [FleetGateway] { [] }
}

struct NoopRoster: FleetRosterProviding {
    func refreshRoster() async -> FleetRosterSnapshot { FleetRosterSnapshot() }
}

struct NoopSessionList: SessionListProviding {
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
}

struct NoopHealth: ConnectionHealthAccumulating {
    func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
    func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
    func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
    func rehydrate(gatewayIDs: [GatewayID]) async {}
    func forget(gatewayID: GatewayID) async {}
}
#endif
