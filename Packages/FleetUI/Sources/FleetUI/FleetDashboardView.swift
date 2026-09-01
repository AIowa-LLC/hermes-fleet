import SwiftUI
import FleetCore
import FleetPersistence

/// Fleet dashboard — the Home tab (U3 Gold Fleet).
///
/// REAL DATA ONLY: the overview stats derive from the live `AppEnvironment`
/// (registered gateway count, roster bot count, connected-gateway fraction —
/// each computed, never fabricated). Sections list the registered gateways
/// with their live connection state and the roster's active bots; empty
/// sections are honest gaps that deep-link to their tab, not defects.
///
/// U4 (next card) replaces the summary sections with the full Gold Fleet
/// dashboard composition (StatCard grid + gateway/bot rows + activity feed).
public struct FleetDashboardView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                overviewStats
                gatewaysSection
                activeBotsSection
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingXl)
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .navigationTitle("Home")
        .accessibilityIdentifier("fleet.dashboard")
    }

    // MARK: Overview stats (real counts only)

    private var overviewStats: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            StatCard(
                icon: "cpu",
                tint: FleetTheme.accentMagenta,
                value: "\(environment.rosterSnapshot?.roster.allBots.count ?? 0)",
                label: "Bots"
            )
            StatCard(
                icon: "server.rack",
                tint: FleetTheme.accentCyan,
                value: "\(environment.gateways.count)",
                label: "Gateways"
            )
            StatCard(
                icon: "antenna.radiowaves.left.and.right",
                tint: fleetHealthTint,
                value: connectedFractionText,
                label: "Connected"
            )
        }
        .accessibilityIdentifier("fleet.dashboard.stats")
    }

    /// Connected-gateway fraction over the registered fleet (0/0 renders "—").
    private var connectedFractionText: String {
        let total = environment.gateways.count
        guard total > 0 else { return "—" }
        let connected = environment.gateways.filter {
            environment.connectionStates[$0.id] == .connected
        }.count
        return "\(connected)/\(total)"
    }

    /// Tint by fleet-wide connectivity: any connected → online green,
    /// any connecting → idle amber, else offline gray (no fabrication).
    private var fleetHealthTint: Color {
        let states = environment.gateways.compactMap { environment.connectionStates[$0.id] }
        if states.contains(.connected) { return FleetTheme.statusOnline }
        if states.contains(.connecting) { return FleetTheme.statusIdle }
        return FleetTheme.statusOffline
    }

    // MARK: Gateways summary (registry truth)

    private var gatewaysSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Gateways")
            if environment.gateways.isEmpty {
                emptyHint(
                    icon: "server.rack",
                    text: "No gateways registered. Add one from the Gateways tab."
                )
                .accessibilityIdentifier("fleet.dashboard.gateways.empty")
            } else {
                VStack(spacing: FleetTheme.spacingSm) {
                    ForEach(environment.gateways) { gateway in
                        gatewayRow(gateway)
                    }
                }
            }
        }
        .accessibilityIdentifier("fleet.dashboard.gateways")
    }

    private func gatewayRow(_ gateway: FleetGateway) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "server.rack")
                    .foregroundStyle(FleetTheme.accentCyan)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gateway.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(gateway.endpoint.map(Redaction.redactedURL) ?? gateway.id.rawValue)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                StatusPill(status: gatewayPillStatus(gateway.id))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.dashboard.gateway.\(gateway.id.rawValue)")
    }

    private func gatewayPillStatus(_ id: GatewayID) -> FleetStatus {
        FleetStatus(gatewayStatus: pillGatewayStatus(environment.connectionStates[id]))
    }

    /// Observable connection state → the `GatewayStatus` vocabulary the
    /// FleetStatus mapping consumes (idle/disconnected render offline-gray —
    /// an unconnected gateway is not "degraded", it is simply not connected).
    private func pillGatewayStatus(_ state: GatewayConnectionState?) -> GatewayStatus {
        switch state {
        case .connected: return .online
        case .connecting: return .connecting
        case .idle, .disconnected, nil: return .offline
        case .failed(let status): return status
        }
    }

    // MARK: Active bots summary (roster truth)

    private var activeBotsSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Active Bots")
            if let bots = environment.rosterSnapshot?.roster.allBots, !bots.isEmpty {
                VStack(spacing: FleetTheme.spacingSm) {
                    ForEach(bots.prefix(10)) { bot in
                        botRow(bot)
                    }
                }
            } else {
                emptyHint(
                    icon: "cpu",
                    text: "No bots reported yet. The roster refreshes from your gateways."
                )
                .accessibilityIdentifier("fleet.dashboard.bots.empty")
            }
        }
        .accessibilityIdentifier("fleet.dashboard.bots")
    }

    private func botRow(_ bot: FleetBot) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "cpu")
                    .foregroundStyle(FleetTheme.accentMagenta)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(bot.route.gatewayID.rawValue)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(status: FleetStatus(activity: bot.activity))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.dashboard.bot.\(bot.route.gatewayID.rawValue)#\(bot.route.profileSlug.rawValue)")
    }

    // MARK: Empty hint (an honest gap, not a fabricated state)

    private func emptyHint(icon: String, text: String) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: icon)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
#Preview("Dashboard — empty fleet") {
    NavigationStack {
        FleetDashboardView(
            environment: AppEnvironment(
                registry: PreviewRegistry(),
                roster: PreviewRoster(),
                cache: try! SwiftDataCacheStore.makeInMemory(),
                sessionList: PreviewSessionList(),
                connectionFactory: { gateway, _ in PreviewConnection(gatewayID: gateway.id) },
                health: PreviewHealthAccumulator()
            )
        )
    }
    .preferredColorScheme(.dark)
}

private struct PreviewConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {}
    func disconnect() async {}
    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

private struct PreviewRegistry: GatewayRegistryManaging {
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

private struct PreviewRoster: FleetRosterProviding {
    func refreshRoster() async -> FleetRosterSnapshot {
        FleetRosterSnapshot()
    }
}

private struct PreviewSessionList: SessionListProviding {
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
}

private struct PreviewHealthAccumulator: ConnectionHealthAccumulating {
    func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
    func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
    func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
    func rehydrate(gatewayIDs: [GatewayID]) async {}
    func forget(gatewayID: GatewayID) async {}
}
#endif
