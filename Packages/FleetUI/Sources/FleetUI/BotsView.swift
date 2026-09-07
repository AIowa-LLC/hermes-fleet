import SwiftUI
import FleetCore

/// Bots on a specific gateway (drilled from the gateways list).
///
/// Reads the union roster snapshot from `AppEnvironment` and lists the bots
/// owned by the selected gateway. Renders the gateway's partial-outage state
/// when the roster refresh classified it unreachable (spec §31 partial
/// availability / §30 "which gateway failed") instead of silently showing an
/// empty list. Tapping a bot drills into its Bot detail (U2).
///
/// U5 (Gold Fleet re-skin): rows render on the design system — `FleetCard`
/// surfaces with the avatar component, name, model/provider subtitle, and a
/// `StatusPill` from the bot's real activity. Presentation-layer only.
public struct BotsView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID

    public init(environment: AppEnvironment, gatewayID: GatewayID) {
        self.environment = environment
        self.gatewayID = gatewayID
    }

    public var body: some View {
        let bots = environment.bots(on: gatewayID)
        let outcome = environment.rosterSnapshot?.outcome(for: gatewayID)
        Group {
            if isUnreachable(outcome) {
                outageState(outcome)
            } else if bots.isEmpty {
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

    private func isUnreachable(_ outcome: GatewayRosterOutcome?) -> Bool {
        guard let outcome else { return false }
        if case .failed = outcome { return true }
        return false
    }

    private func botList(_ bots: [FleetBot]) -> some View {
        ScrollView {
            LazyVStack(spacing: FleetTheme.spacingSm, pinnedViews: []) {
                ForEach(bots) { bot in
                    NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                        botRow(bot)
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.bots.row.\(bot.route.id)")
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingSm)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FleetTheme.background)
    }

    /// U5 row spec: avatar + name + model/provider subtitle + status pill.
    /// P0-7: pill derives from roster presence (owning gateway answered) with
    /// live activity as refinement; the "own gateway process" badge is a
    /// subtle secondary signal, never the primary online/offline.
    private func botRow(_ bot: FleetBot) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(displayName: bot.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                        .lineLimit(2)
                    // V3: the canonical route is identity data — terminal mono.
                    Text(bot.route.id)
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let model = bot.model, let provider = bot.provider {
                        Text("\(model) · \(provider)")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                    }
                    if bot.gatewayRunning {
                        GatewayRunningBadge(isRunning: true)
                    }
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
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Bots")
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        } description: {
            Text("No profiles reported for this gateway. Connect and refresh the roster.")
        }
        .accessibilityIdentifier("fleet.bots.empty")
    }

    private func outageState(_ outcome: GatewayRosterOutcome?) -> some View {
        let status = statusText(outcome)
        let detail = detailText(outcome)
        return ContentUnavailableView {
            Label {
                Text(status)
            } icon: {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(FleetTheme.statusDegraded)
            }
        } description: {
            Text(detail)
        } actions: {
            Button("Retry") {
                Task { await environment.refreshRoster() }
            }
        }
        .accessibilityIdentifier("fleet.bots.outage")
    }

    private func statusText(_ outcome: GatewayRosterOutcome?) -> String {
        guard case .failed(let status, _) = outcome else { return "Unreachable" }
        switch status {
        case .online: return "Online"
        case .connecting: return "Connecting…"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Auth Required"
        case .offline: return "Unreachable"
        case .unsupported: return "Unsupported"
        }
    }

    private func detailText(_ outcome: GatewayRosterOutcome?) -> String {
        if case .failed(let status, let detail) = outcome {
            return GatewayFailureCopy.detail(status: status, detail: detail)
        }
        return "This gateway did not report its roster. Refresh to retry."
    }
}
