import SwiftUI
import FleetCore

/// Fleet-wide Bots roster (U2) — the M8 union aggregation rendered.
///
/// Shows EVERY registered gateway in per-gateway sections, each with the bots
/// it reported via `profiles.list` (owning gateway preserved by `Route`).
/// Partial-outage resilience (spec §31 Multi-Gateway / §30): a gateway that
/// failed the refresh renders its classified §13 status + non-secret detail
/// as an outage section while the reachable gateways' bots stay visible —
/// the fleet stays useful when partially available.
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
        List {
            ForEach(sections) { section in
                Section {
                    if let (status, detail) = section.outage {
                        outageRow(gateway: section.gateway, status: status, detail: detail)
                    } else {
                        ForEach(section.bots) { bot in
                            NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                                BotRowView(bot: bot)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("fleet.roster.row.\(bot.route.id)")
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: section.outage == nil ? "server.rack" : "wifi.slash")
                            .foregroundStyle(section.outage == nil ? FleetTheme.textSecondary : FleetTheme.accent)
                            .fixedSize()
                        Text(section.gateway.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let outage = section.outage {
                            Text(statusText(outage.0))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FleetTheme.accent)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
        .accessibilityIdentifier("fleet.roster.list")
    }

    private func outageRow(gateway: FleetGateway, status: GatewayStatus, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(statusText(status), systemImage: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FleetTheme.textPrimary)
            Text(detailNonEmpty(detail))
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
        }
        .padding(.vertical, 4)
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
                    .foregroundStyle(FleetTheme.accent)
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
                    .foregroundStyle(FleetTheme.accent)
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

    private func detailNonEmpty(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return "This gateway did not report its roster this refresh."
        }
        return detail
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

/// A bot row in the union roster: display name + canonical route identity.
private struct BotRowView: View {
    let bot: FleetBot

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(2)
                Text(bot.route.id)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let model = bot.model, let provider = bot.provider {
                    Text("\(model) · \(provider)")
                        .font(.caption2)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 2)
    }
}
