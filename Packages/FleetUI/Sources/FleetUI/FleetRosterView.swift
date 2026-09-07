import SwiftUI
import FleetCore

/// Fleet-wide Bots roster (U2 → U5 Gold Fleet re-skin) — the M8 union
/// aggregation rendered.
///
/// Shows EVERY registered gateway in per-gateway sections, each with the bots
/// it reported via `profiles.list` (owning gateway preserved by `Route`).
/// Partial-outage resilience (spec §31 Multi-Gateway / §30): a gateway that
/// failed the refresh renders its classified §13 status + non-secret detail
/// as an outage section while the reachable gateways' bots stay visible —
/// the fleet stays useful when partially available.
///
/// U5: sections render on the design system — `SectionHeader`s per gateway,
/// bot rows as `FleetCard`s with the shared avatar component, name, route,
/// model/provider subtitle, and a `StatusPill` from the bot's real activity.
/// Presentation-layer only.
///
/// States: no snapshot yet (refreshing), empty fleet, one gateway, multiple
/// gateways, and partial outage all render explicitly.
public struct FleetRosterView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            if environment.rosterSnapshot == nil {
                refreshing
            } else if environment.gateways.isEmpty {
                emptyFleet
            } else if sections.isEmpty {
                noBotsAnywhere
            } else {
                rosterList
            }
        }
        .navigationTitle("Fleet Roster")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await environment.refreshRoster() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(environment.isRefreshing)
                .accessibilityIdentifier("fleet.roster.refresh")
            }
        }
        .task {
            // Re-render from the latest snapshot on entry (idempotent).
            if environment.rosterSnapshot == nil {
                await environment.refreshRoster()
            }
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.roster")
    }

    // MARK: Sections — per-gateway grouping with outage states

    /// Roster sections in stable gateway order: a healthy gateway's bots as a
    /// section, an unreachable gateway as an outage section.
    ///
    /// P2-5: a HEALTHY gateway with zero bots contributes NO section — an
    /// all-healthy, all-empty fleet must render the `noBotsAnywhere` state,
    /// not a row of empty section headers. Outage sections are ALWAYS
    /// preserved (partial-outage resilience): an unreachable gateway still
    /// reports its §13 state even with no bots.
    private var sections: [RosterSection] {
        guard let snapshot = environment.rosterSnapshot else { return [] }
        return Self.sections(from: snapshot)
    }

    private var rosterList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FleetTheme.spacingLg, pinnedViews: []) {
                ForEach(sections) { section in
                    rosterSection(section)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingMd)
        }
        .background(FleetTheme.background)
    }

    private func rosterSection(_ section: RosterSection) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            // Section header: gateway name (+ outage status when unreachable).
            // The gateway-name Text is a UI-test landmark (staticTexts[name]).
            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: section.outage == nil ? "server.rack" : "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(
                        section.outage == nil
                            ? FleetTheme.textSecondary
                            : FleetTheme.statusDegraded
                    )
                    .fixedSize()
                    .accessibilityHidden(true)
                // V3: the gateway name is DATA (UI-test landmark) — stays
                // title-case + primary; the uppercase micro-label role is for
                // generic section labels (see SectionHeader).
                Text(section.gateway.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let outage = section.outage {
                    Text(statusText(outage.0))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(FleetTheme.statusDegraded)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if let (status, detail) = section.outage {
                outageRow(gateway: section.gateway, status: status, detail: detail)
            } else {
                VStack(spacing: FleetTheme.spacingSm) {
                    ForEach(section.bots) { bot in
                        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                            BotRowView(
                                bot: bot,
                                presence: environment.botPresence(for: bot.route)
                            )
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.roster.row.\(bot.route.id)")
                    }
                }
            }
        }
    }

    private func outageRow(gateway: FleetGateway, status: GatewayStatus, detail: String?) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                Label(statusText(status), systemImage: "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                Text(detailNonEmpty(detail, status: status))
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.roster.outage.\(gateway.id.rawValue)")
    }

    // MARK: States

    private var refreshing: some View {
        ContentUnavailableView {
            Label {
                Text("Loading Roster")
            } icon: {
                ProgressView()
            }
        } description: {
            Text("Refreshing every gateway's profiles…")
        }
        .accessibilityIdentifier("fleet.roster.loading")
    }

    private var emptyFleet: some View {
        ContentUnavailableView {
            Label {
                Text("No Gateways")
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        } description: {
            Text("Add a gateway to start building your fleet.")
        }
        .accessibilityIdentifier("fleet.roster.empty")
    }

    private var noBotsAnywhere: some View {
        ContentUnavailableView {
            Label {
                Text("No Bots")
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        } description: {
            Text("No profiles reported. Refresh to re-probe every gateway.")
        }
        .accessibilityIdentifier("fleet.roster.no-bots")
    }

    // MARK: helpers

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

    private func detailNonEmpty(_ detail: String?, status: GatewayStatus = .offline) -> String {
        // F1: the outage line is cause copy (what happened + what to do),
        // not raw transport detail — the classified status drives it, with
        // the non-secret detail used only to sharpen the cause.
        GatewayFailureCopy.detail(status: status, detail: detail)
    }

    /// One per-gateway roster section (healthy bots or an outage).
    public struct RosterSection: Identifiable {
        public let gateway: FleetGateway
        public let bots: [FleetBot]
        /// (status, detail) when this gateway failed its refresh.
        public let outage: (GatewayStatus, String?)?
        public var id: String { gateway.id.rawValue }

        public init(
            gateway: FleetGateway,
            bots: [FleetBot],
            outage: (GatewayStatus, String?)?
        ) {
            self.gateway = gateway
            self.bots = bots
            self.outage = outage
        }
    }

    /// Build the roster sections from a snapshot (P2-5, testable pure logic).
    ///
    /// A healthy gateway with zero bots contributes NO section — an
    /// all-healthy, all-empty fleet must render the No Bots state, not empty
    /// section headers. Outage sections are always preserved.
    public static func sections(from snapshot: FleetRosterSnapshot) -> [RosterSection] {
        snapshot.roster.allGateways.compactMap { gateway in
            if case .failed(let status, let detail) = snapshot.outcome(for: gateway.id) {
                return RosterSection(gateway: gateway, bots: [], outage: (status, detail))
            }
            let bots = snapshot.bots(on: gateway.id)
            guard !bots.isEmpty else { return nil }
            return RosterSection(gateway: gateway, bots: bots, outage: nil)
        }
    }
}

/// A bot row in the union roster (U5): avatar + name + canonical route
/// identity + model/provider + status pill, on a FleetCard.
/// P0-7: the pill derives from roster presence (owning gateway answered)
/// with live activity as refinement — NOT from unobserved activity alone.
private struct BotRowView: View {
    let bot: FleetBot
    let presence: BotPresence

    var body: some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(displayName: bot.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                        .lineLimit(2)
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
                            .truncationMode(.tail)
                    }
                    if bot.gatewayRunning {
                        GatewayRunningBadge(isRunning: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                StatusPill(status: FleetStatus(activity: bot.activity, presence: presence))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
