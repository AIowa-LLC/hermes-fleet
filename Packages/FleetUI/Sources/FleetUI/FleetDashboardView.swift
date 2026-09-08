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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
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
                managementSection
                if sizeClass == .regular && !typeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 24) { activeBotsSection; kanbanSection }
                        VStack(spacing: 24) { gatewaysSection; recentActivitySection }
                    }
                } else {
                    activeBotsSection
                    gatewaysSection
                    kanbanSection
                    recentActivitySection
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingXl)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .navigationTitle("Fleet")
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
        VStack(alignment: .leading, spacing: 12) {
            Label("HERMES FLEET", systemImage: "sparkle")
                .font(.caption.weight(.semibold)).tracking(3)
                .foregroundStyle(FleetTheme.accent)
            Text("Your agents.\nWithin reach.")
                .font(FleetTheme.titleFont)
                .foregroundStyle(FleetTheme.textPrimary)
            Text("A clear view of your fleet. A direct line to your next idea.")
                .font(.subheadline).foregroundStyle(FleetTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [FleetTheme.accent.opacity(0.12), FleetTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .accessibilityIdentifier("fleet.dashboard.title")
    }

    // MARK: Fleet Overview (real counts only)

    private var overviewStats: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Fleet Overview")
            HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
                StatCard(
                    value: "\(environment.rosterSnapshot?.roster.allBots.count ?? 0)",
                    label: "Known Bots"
                )
                StatCard(
                    value: "\(environment.gateways.count)",
                    label: "Gateways"
                )
                StatCard(
                    value: connectedFractionText,
                    label: "Connected"
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

    // MARK: Gateways (registry truth)

    private var gatewaysSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Gateways", destination: FleetScreen.gateways)
                .accessibilityIdentifier("fleet.dashboard.gateways.header")
            if environment.gateways.isEmpty {
                emptyHint(
                    icon: "server.rack",
                    text: "No gateways registered. Add one in Control → Gateways."
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
                    .foregroundStyle(FleetTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gateway.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    // V3: endpoints are machine data — mono, the terminal voice.
                    Text(gateway.endpoint.map(Redaction.redactedURL) ?? gateway.id.rawValue)
                        .font(FleetTheme.monoFont)
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
            SectionHeader(title: "Agents", destination: FleetScreen.roster)
                .accessibilityIdentifier("fleet.dashboard.bots.header")
            if let bots = environment.rosterSnapshot?.roster.allBots, !bots.isEmpty {
                VStack(spacing: FleetTheme.spacingSm) {
                    ForEach(bots.prefix(10)) { bot in
                        NavigationLink(value: FleetScreen.botDetail(bot.route)) { botRow(bot) }
                            .buttonStyle(.fleetPressable)
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
                BotAvatar(bot: bot, management: environment.botManagement)
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
        let session = bot.latestSession?.title
        return "\(gatewayName) · \(session?.isEmpty == false ? session! : "No named conversation")"
    }

    // MARK: Kanban board entry (t_3b321b7b)

    /// A single card linking into the live read-only Kanban board — only
    /// when a watcher can be built (fail closed: no factory, no entry).
    @ViewBuilder
    private var kanbanSection: some View {
        if environment.gateways.first(where: { environment.makeKanbanWatcher(for: $0) != nil }) != nil {
            SectionHeader(title: "Kanban Board", destination: FleetScreen.kanban)
                .accessibilityIdentifier("fleet.dashboard.kanban.header")
            NavigationLink(value: FleetScreen.kanban) {
                FleetCard {
                    HStack(spacing: FleetTheme.spacingMd) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(FleetTheme.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live Board")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(FleetTheme.textPrimary)
                            Text("Cards by status, updating in real time")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.fleetPressable)
            .accessibilityIdentifier("fleet.dashboard.kanban.entry")
        }
    }

    // MARK: Management panes (R9-T5 cron + R9-T6 skills)

    private var managementSection: some View {
        NavigationLink(value: FleetScreen.gateways) {
            Label("Gateway tools", systemImage: "server.rack")
        }.accessibilityIdentifier("fleet.dashboard.management.entry")
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
                    // V3: timestamps are telemetry — mono caption.
                    Text(FleetDashboardFormatting.relativeTime(from: at, since: now))
                        .font(FleetTheme.monoCaptionFont)
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
