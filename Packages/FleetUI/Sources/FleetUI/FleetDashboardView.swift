import SwiftUI
import FleetCore
import FleetPersistence

/// Home dashboard (U4 Gold Fleet) — the full composition per the plan card:
/// gold "Hermes Fleet" masthead, Fleet Overview stat row, Gateways rows,
/// Active Bots rows (avatar initials + gateway + last-active), and a Recent
/// Activity timeline derived from real gateway events.
///
/// REAL DATA ONLY: every stat, row, and timeline entry derives from the live
/// `AppEnvironment` (registered gateways, union roster, observable connection
/// states, H2 accumulated health stats) — computed, never fabricated. Empty
/// sections are honest gaps with a hint, not defects (empty ≠ broken).
///
/// Section "View All" actions drill into the existing surfaces on the Home
/// tab's own NavigationStack (registry cockpit / union roster / activity
/// feed) — presentation-layer navigation only, no logic changes.
public struct FleetDashboardView: View {
    private let environment: AppEnvironment

    /// Local drill-in path for the section View All actions. Rides the tab's
    /// OWN NavigationStack (no nested stack): the typed `FleetScreen` routes
    /// registered by the tab shell cover `.gateways` / `.roster` / `.activity`
    /// (U4 additions), so pushes here behave identically to pushes from any
    /// other tab surface.
    @State private var now = Date()

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                masthead
                overviewStats
                gatewaysSection
                activeBotsSection
                recentActivitySection
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingXl)
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("fleet.dashboard")
        .task {
            // Keep relative timestamps (last-active / activity) fresh while
            // the dashboard is visible; cheap 60s tick.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Masthead (gold brand title per the hero mock)

    private var masthead: some View {
        Text("Hermes Fleet")
            .font(FleetTheme.titleFont)
            .foregroundStyle(FleetTheme.accentGold)
            .accessibilityIdentifier("fleet.dashboard.title")
    }

    // MARK: Fleet Overview (real counts only)

    private var overviewStats: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Fleet Overview")
            HStack(spacing: FleetTheme.spacingMd) {
                StatCard(
                    icon: "cpu",
                    tint: FleetTheme.accentMagenta,
                    value: "\(environment.rosterSnapshot?.roster.allBots.count ?? 0)",
                    label: "Active Bots"
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
                    label: "Fleet Health"
                )
            }
        }
        .accessibilityIdentifier("fleet.dashboard.stats")
    }

    /// Connected-gateway fraction over the registered fleet (0/0 renders "—").
    private var connectedFractionText: String {
        FleetDashboardFormatting.connectedFraction(gateways: environment.gateways) { gateway in
            environment.connectionStates[gateway.id] == .connected
        }
    }

    /// Tint by real fleet connectivity (any connected → online green, any
    /// connecting → idle amber, else offline gray — no fabrication).
    private var fleetHealthTint: Color {
        switch FleetDashboardFormatting.connectivity(
            gateways: environment.gateways,
            state: { environment.connectionStates[$0.id] }
        ) {
        case .online: FleetTheme.statusOnline
        case .connecting: FleetTheme.statusIdle
        case .offline, .empty: FleetTheme.statusOffline
        }
    }

    // MARK: Gateways (registry truth)

    private var gatewaysSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Gateways", destination: FleetScreen.gateways)
                .accessibilityIdentifier("fleet.dashboard.gateways.header")
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
        // NOTE: no container-level accessibilityIdentifier here — on
        // non-AX containers SwiftUI forwards it to descendants and it
        // would override the per-row identifiers (observed via AX dump).
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

    // MARK: Active Bots (roster truth; avatar + gateway + last-active)

    private var activeBotsSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Active Bots", destination: FleetScreen.roster)
                .accessibilityIdentifier("fleet.dashboard.bots.header")
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
        // NOTE: no container-level accessibilityIdentifier (see gateways).
    }

    private func botRow(_ bot: FleetBot) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(displayName: bot.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(botSubtitle(bot))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(
                    status: FleetStatus(
                        activity: bot.activity,
                        presence: environment.botPresence(for: bot.route)
                    )
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.dashboard.bot.\(bot.route.gatewayID.rawValue)#\(bot.route.profileSlug.rawValue)")
    }

    /// "Gateway · Active 3m ago" from real roster data (no sessions → honest
    /// "No sessions yet"; the fleet has no per-bot uptime signal today).
    private func botSubtitle(_ bot: FleetBot) -> String {
        let gatewayName = environment.gateway(for: bot.route.gatewayID)?.displayName
            ?? bot.route.gatewayID.rawValue
        return "\(gatewayName) · \(FleetDashboardFormatting.lastActiveLabel(bot: bot, now: now))"
    }

    // MARK: Recent Activity (real gateway events from the H2 accumulator)

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Recent Activity", destination: FleetScreen.activity)
                .accessibilityIdentifier("fleet.dashboard.activity.header")
            let entries = FleetDashboardFormatting.activityEntries(
                gateways: environment.gateways,
                stats: environment.healthStats
            )
            if entries.isEmpty {
                emptyHint(
                    icon: "clock.arrow.circlepath",
                    text: "No connection activity recorded yet. Events appear as gateways connect."
                )
                .accessibilityIdentifier("fleet.dashboard.activity.empty")
            } else {
                VStack(spacing: FleetTheme.spacingSm) {
                    ForEach(entries) { entry in
                        activityRow(entry)
                    }
                }
            }
        }
        .task {
            // Copy the latest accumulated stats on entry (the accumulator is
            // fed by the composition root's transport feed regardless).
            await environment.refreshHealthStats()
        }
    }

    private func activityRow(_ entry: FleetDashboardFormatting.ActivityEntry) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: entry.icon)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(entry.text)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(2)
                Spacer()
                if let at = entry.at {
                    Text(FleetDashboardFormatting.relativeTime(from: at, since: now))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.dashboard.activity.row.\(entry.id)")
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
