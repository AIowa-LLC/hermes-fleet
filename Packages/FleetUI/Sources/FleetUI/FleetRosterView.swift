import SwiftUI
import FleetCore

/// Fleet-wide Bots roster — True Bots Mode slice 2 (D02 UI).
///
/// Shows EVERY registered gateway in per-gateway sections, each with the bots
/// it reported via `profiles.list` (owning gateway preserved by `Route`).
/// Partial-outage resilience: a gateway that failed the refresh renders its
/// classified §13 status as an outage section while reachable gateways' bots
/// stay visible — the fleet stays useful when partially available.
///
/// Slice 2 layers (pure logic in `BotRosterPresentation`, this view only
/// renders):
/// - Activity ordering: pinned first, then botActivitySession recency
///   (fresher of canonical vs last_session).
/// - Preview + relative time per row from the activity anchor.
/// - "Active Now" strip from live activity signals.
/// - Search across title/slug/route/description/preview/gateway label.
/// - Hidden bots hidden by default; eye toggle reveals them dimmed.
/// - User sections inside each gateway (registry order, unassigned last,
///   no fabricated header) — D10 rendering.
/// - Duplicate-name "· <gateway>" disambiguation labels.
/// - Offline-gateway ghost rows retain identity (cached snapshot reuse).
/// - Rooms: group rows from the landed FleetRoomUnion provider (hosted +
///   legacy, honest "Managed by Hermes Desktop" labels, distinct rows).
public struct FleetRosterView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID?
    private var visibleGateways: [FleetGateway] { environment.gateways.filter { gatewayID == nil || $0.id == gatewayID } }

    @State private var searchText = ""
    @State private var revealingHidden = false
    @State private var showingCreate = false
    @State private var sectionsGateway: FleetGateway?
    @State private var createRoomGateway: FleetGateway?
    /// Slice 8: collapsed section ids (per gateway+section). Search
    /// temporarily expands everything — collapsing is a browsing aid, never
    /// a way to lose a search match.
    @State private var collapsedSections: Set<String> = []

    public init(environment: AppEnvironment, gatewayID: GatewayID? = nil) {
        self.environment = environment
        self.gatewayID = gatewayID
    }

    private var hiddenBotsActive: Bool {
        visibleGateways.flatMap { environment.bots(on: $0.id) }
            .contains { environment.botPresence(for: $0.route) != .unreachable && HiddenBotActivity.hasSignal($0) }
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
        .navigationTitle("Bots")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("Create Bot", systemImage: "plus")
                    }
                    .accessibilityIdentifier("fleet.roster.create")
                    ForEach(visibleGateways) { gateway in
                        Button {
                            createRoomGateway = gateway
                        } label: {
                            Label("Create Room — \(gateway.displayName)", systemImage: "person.3")
                        }
                        .disabled(!environment.canCreateRooms(on: gateway.id))
                        .accessibilityIdentifier("fleet.roster.createroom.\(gateway.id.rawValue)")
                        Button {
                            sectionsGateway = gateway
                        } label: {
                            Label("Edit Sections — \(gateway.displayName)", systemImage: "folder")
                        }
                        .accessibilityIdentifier("fleet.roster.sections.\(gateway.id.rawValue)")
                    }
                } label: {
                    Label("Manage", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("fleet.roster.manage")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await environment.refreshRoster() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(environment.isRefreshing)
                .accessibilityIdentifier("fleet.roster.refresh")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    revealingHidden.toggle()
                } label: {
                    Label(
                        revealingHidden ? "Hide Hidden Bots" : (hiddenBotsActive ? "Hidden Bots Active" : "Show Hidden Bots"),
                        systemImage: revealingHidden ? "eye.slash" : (hiddenBotsActive ? "eye.trianglebadge.exclamationmark" : "eye")
                    )
                }
                .accessibilityIdentifier("fleet.roster.hidden-toggle")
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateBotSheet(environment: environment) { _, _ in }
        }
        .sheet(item: $sectionsGateway) { gateway in
            SectionsManagementSheet(environment: environment, gateway: gateway)
        }
        .sheet(item: $createRoomGateway) { gateway in
            CreateRoomSheet(environment: environment, gateway: gateway) { _ in }
        }
        .searchable(text: $searchText, prompt: "Bots, rooms, gateways")
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

    private var sections: [RosterSection] {
        guard let snapshot = environment.rosterSnapshot else { return [] }
        return Self.sections(from: snapshot, cachedBots: environment.cachedBotsByGateway).filter { gatewayID == nil || $0.gateway.id == gatewayID }
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
            gatewayHeader(section)

            if let (status, detail) = section.outage {
                outageRow(gateway: section.gateway, status: status, detail: detail)
                // Ghost rows: a failed refresh still shows the CACHED bots
                // (identity retained, dimmed) — never a same-name twin.
                if !section.bots.isEmpty {
                    Text("Last known bots")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    ForEach(section.bots) { bot in
                        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                            BotRowView(
                management: environment.botManagement,
                                bot: bot,
                                presence: .unreachable,
                                anchor: BotRosterPresentation.activityAnchor(for: bot),
                                duplicateLabel: nil,
                                dimmed: true
                            )
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.roster.row.\(bot.route.id)")
                    }
                }
            } else {
                botGroups(for: section)
                roomsGroup(for: section.gateway)
            }
        }
    }

    /// User-section blocks (D10): registry order; each block a header + rows;
    /// unassigned last with NO fabricated header; no sections → plain rows.
    private func botGroups(for section: RosterSection) -> some View {
        let registry = environment.botManagement.sectionsByGateway[section.gateway.id] ?? []
        let gatewayLabel = section.gateway.displayName
        let rows = BotRosterPresentation.filter(
            BotRosterPresentation.order(section.bots),
            query: searchText,
            gatewayLabel: { _ in gatewayLabel },
            revealingHidden: revealingHidden
        )
        let duplicateLabels = BotRosterPresentation.duplicateNameRoutes(
            BotRosterPresentation.visible(section.bots, revealingHidden: revealingHidden),
            gatewayLabel: { _ in gatewayLabel }
        )
        return VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            activeNowStrip(rows: rows)
            if BotSectionRegistry.rendersSections(registry) {
                let blocks = BotSectionRegistry.split(
                    rows,
                    sectionID: { $0.botModeMetadata?.sectionID },
                    sections: registry
                )
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if !block.isUnassigned {
                        sectionHeader(block: block, rowCount: block.rows.count)
                    }
                    if !block.isUnassigned && isCollapsed(block) {
                        // Slice 8: honest collapsed affordance — name the
                        /// count so a collapsed section never reads as empty.
                        Text(block.rows.isEmpty ? "No bots" : "\(block.rows.count) bot\(block.rows.count == 1 ? "" : "s")")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .padding(.leading, FleetTheme.spacingLg)
                            .accessibilityIdentifier("fleet.roster.section-count.\(block.id ?? "")")
                    } else {
                        ForEach(block.rows) { bot in
                            botRow(bot, duplicateLabels: duplicateLabels, gatewayLabel: gatewayLabel)
                        }
                        if !block.isUnassigned && block.rows.isEmpty {
                            Text("Empty — move bots here from a bot's actions menu.")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .padding(.leading, FleetTheme.spacingLg)
                                .accessibilityIdentifier("fleet.roster.section-empty.\(block.id ?? "")")
                        }
                    }
                }
            } else {
                ForEach(rows) { bot in
                    botRow(bot, duplicateLabels: duplicateLabels, gatewayLabel: gatewayLabel)
                }
            }
        }
    }

    /// Slice 8: tappable section header — tap toggles collapse. Label names
    /// the state ("Collapse Research" / "Expand Research") so it is never
    /// color- or chevron-only. Skipped while searching (all expanded).
    private func sectionHeader(block: SectionBlock<FleetBot>, rowCount: Int) -> some View {
        let collapsed = isCollapsed(block)
        return Button {
            withAnimation {
                if collapsed {
                    collapsedSections.remove(block.id ?? "")
                } else if let id = block.id {
                    collapsedSections.insert(id)
                }
            }
        } label: {
            SectionHeader(title: collapsed ? "\(block.name) — \(rowCount)" : block.name)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fleet.roster.section.\(block.id ?? "")")
        .accessibilityLabel(collapsed ? "Expand \(block.name)" : "Collapse \(block.name)")
    }

    private func isCollapsed(_ block: SectionBlock<FleetBot>) -> Bool {
        guard let id = block.id else { return false }
        return searchText.isEmpty && collapsedSections.contains(id)
    }

    @ViewBuilder
    private func botRow(
        _ bot: FleetBot,
        duplicateLabels: [Route: String],
        gatewayLabel: String
    ) -> some View {
        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
            BotRowView(
                management: environment.botManagement,
                bot: bot,
                presence: environment.botPresence(for: bot.route),
                anchor: BotRosterPresentation.activityAnchor(for: bot),
                duplicateLabel: duplicateLabels[bot.route],
                dimmed: bot.botModeMetadata?.hidden == true
            )
        }
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.roster.row.\(bot.route.id)")
    }

    /// Active Now strip: live-signal bots (never fabricated).
    @ViewBuilder
    private func activeNowStrip(rows: [FleetBot]) -> some View {
        let active = rows.filter(BotRosterPresentation.isActiveNow)
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                SectionHeader(title: "Active Now")
                    .accessibilityIdentifier("fleet.roster.active-now")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FleetTheme.spacingSm) {
                        ForEach(active) { bot in
                            NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(FleetTheme.statusOnline)
                                        .frame(width: 8, height: 8)
                                    Text(BotRosterPresentation.displayTitle(for: bot))
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(FleetTheme.textPrimary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, FleetTheme.spacingSm)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(FleetTheme.surfaceElevated))
                                .overlay(Capsule().strokeBorder(FleetTheme.statusOnline.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.fleetPressable)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("fleet.roster.active.\(bot.route.id)")
                        }
                    }
                }
            }
        }
    }

    /// Rooms group: rows from the room union (hosted + desktop legacy).
    @ViewBuilder
    private func roomsGroup(for gateway: FleetGateway) -> some View {
        let rooms = environment.rooms(for: gateway.id)
        let visible = searchText.isEmpty
            ? rooms
            : rooms.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        if !visible.isEmpty {
            SectionHeader(title: "Rooms")
                .accessibilityIdentifier("fleet.roster.rooms")
            ForEach(visible) { room in
                NavigationLink(value: FleetScreen.room(room.id)) {
                    RoomRowView(room: room)
                }
                .buttonStyle(.fleetPressable)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fleet.room.row.\(room.id.key)")
            }
        }
    }

    private func gatewayHeader(_ section: RosterSection) -> some View {
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
        GatewayFailureCopy.detail(status: status, detail: detail)
    }

    /// One per-gateway roster section (healthy bots or an outage + ghosts).
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
    /// A healthy gateway with zero bots contributes NO section. Outage
    /// sections are always preserved — and now carry the gateway's CACHED
    /// bots (from the previous successful refresh) as offline ghosts: their
    /// identity is retained, never substituted by a same-name profile from
    /// another gateway.
    public static func sections(
        from snapshot: FleetRosterSnapshot,
        cachedBots: [GatewayID: [FleetBot]] = [:]
    ) -> [RosterSection] {
        snapshot.roster.allGateways.compactMap { gateway in
            if case .failed(let status, let detail) = snapshot.outcome(for: gateway.id) {
                let ghosts = cachedBots[gateway.id] ?? []
                return RosterSection(gateway: gateway, bots: ghosts, outage: (status, detail))
            }
            let bots = snapshot.bots(on: gateway.id)
            guard !bots.isEmpty else { return nil }
            return RosterSection(gateway: gateway, bots: bots, outage: nil)
        }
    }
}

/// A bot row (slice 2 anatomy): avatar | title (+dup label) + preview/time |
/// status pill; dimmed when hidden-revealed or a ghost.
struct BotRowView: View {
    let management: BotManagementController
    let bot: FleetBot
    let presence: BotPresence
    let anchor: BotRosterPresentation.ActivityAnchor
    let duplicateLabel: String?
    let dimmed: Bool

    var body: some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(bot: bot, management: management)
                    .opacity(dimmed ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(BotRosterPresentation.displayTitle(for: bot))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FleetTheme.textPrimary)
                            .lineLimit(1)
                        if let duplicateLabel {
                            Text("· \(duplicateLabel)")
                                .font(.caption)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .lineLimit(1)
                        }
                        if bot.botModeMetadata?.hidden == true {
                            Image(systemName: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .accessibilityLabel("Hidden")
                        }
                    }
                    if let preview = anchor.preview, !preview.isEmpty {
                        Text(preview)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 4) {
                        Text(bot.route.id)
                        if anchor.lastActive > 0 {
                            Text("· \(BotRowView.relativeTime(anchor.lastActive))")
                        }
                    }
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                StatusPill(status: FleetStatus(activity: bot.activity, presence: presence))
            }
            .opacity(dimmed ? 0.55 : 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Short relative-time copy ("now", "5m", "3h", "2d") from epoch seconds.
    static func relativeTime(_ epoch: Double, now: Double = Date().timeIntervalSince1970) -> String {
        let delta = max(0, now - epoch)
        switch delta {
        case ..<60: return "now"
        case ..<3600: return "\(Int(delta / 60))m"
        case ..<86_400: return "\(Int(delta / 3600))h"
        default: return "\(Int(delta / 86_400))d"
        }
    }
}

/// A room row: name, last speaker + preview, provenance label for legacy
/// rooms, needs-attention badge only from real capability state.
struct RoomRowView: View {
    let room: FleetRoom

    var body: some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                RoomAvatar(members: room.members.map(\.name))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(room.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FleetTheme.textPrimary)
                            .lineLimit(1)
                        if room.isManagedByDesktop {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .accessibilityLabel("Managed by Hermes Desktop, read-only")
                        }
                    }
                    if let last = room.recentLog.last {
                        Text("\(last.from.name): \(last.text)")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if !room.members.isEmpty {
                        Text(room.members.map(\.name).joined(separator: ", "))
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                    }
                    if room.isManagedByDesktop {
                        Text("Managed by Hermes Desktop")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Composite room avatar: up to 4 member initials in a 2×2 grid.
struct RoomAvatar: View {
    let members: [String]

    var body: some View {
        let chips = Array(members.prefix(4))
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(FleetTheme.surfaceElevated)
            if chips.isEmpty {
                Image(systemName: "person.3")
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
            } else {
                GeometryReader { geo in
                    let cols = chips.count == 1 ? 1 : 2
                    let rows = (chips.count + cols - 1) / cols
                    let w = geo.size.width / CGFloat(cols)
                    let h = geo.size.height / CGFloat(rows)
                    ForEach(Array(chips.enumerated()), id: \.offset) { i, name in
                        Text(FleetDashboardFormatting.avatarInitials(from: name))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(FleetTheme.accent)
                            .frame(width: w, height: h)
                            .position(
                                x: (CGFloat(i % cols) + 0.5) * w,
                                y: (CGFloat(i / cols) + 0.5) * h
                            )
                    }
                }
            }
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
}
