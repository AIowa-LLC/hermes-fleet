import SwiftUI
import FleetCore

/// Fleet-wide Bots collection — FOS-5 (SPEC §9).
///
/// Shows EVERY registered gateway in per-gateway sections (or the filtered
/// subset), each with the bots it reported via `profiles.list` (owning
/// gateway preserved by `Route`).
///
/// FOS-5 layers on the slice-2 base:
/// - ONE fleet-wide "Active Now" preview above the groups (§7 execution
///   definition: working/thinking/using tool ONLY — waiting and
///   needs-attention stay distinct); the per-gateway strips are gone.
/// - All gateways filter + All / Bots / Groups scope (`Scope` picker).
/// - Groups terminology: user-facing "Groups"; "room" stays the internal
///   identity term (FleetRoom, FleetRoomID unchanged).
/// - Duplicate-name disambiguation is computed over the WHOLE fleet,
///   including offline ghosts — not per gateway.
/// - Ghost rows apply search equally and dim the PORTRAIT, not the text.
/// - Collapse state is keyed `(GatewayID, SectionID)` — a section id is
///   unique only inside its registry.
/// - Partial-outage resilience: a gateway that failed the refresh renders
///   its classified §13 status as an outage section while reachable
///   gateways' bots stay visible.
public struct FleetRosterView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID?

    @State private var searchText = ""
    @State private var revealingHidden = false
    @State private var showingCreate = false
    @State private var sectionsGateway: FleetGateway?
    @State private var createRoomGateway: FleetGateway?
    /// FOS-5 (SPEC §9): All / Bots / Groups scope over the collection.
    @State private var scope: BotRosterPresentation.Scope = .all
    /// FOS-5 (SPEC §9): All-gateways filter (nil) or one gateway. Only
    /// offered on the fleet-root roster; a pushed per-gateway roster keeps
    /// its fixed gateway.
    @State private var gatewayFilter: GatewayID?
    /// Slice 8 → FOS-5: collapsed section ids keyed GATEWAY+SECTION (SPEC
    /// §9 — collapse state is keyed by `(GatewayID, SectionID)`, not
    /// SectionID alone). Search temporarily expands everything — collapsing
    /// is a browsing aid, never a way to lose a search match.
    @State private var collapsedSections: Set<String> = []

    public init(environment: AppEnvironment, gatewayID: GatewayID? = nil) {
        self.environment = environment
        self.gatewayID = gatewayID
    }

    /// The gateways this roster renders: the fixed `gatewayID` when pushed
    /// (Bots on this Gateway), else the All-gateways filter's selection.
    private var visibleGateways: [FleetGateway] {
        let fixed = environment.gateways.filter { gatewayID == nil || $0.id == gatewayID }
        guard gatewayID == nil, let gatewayFilter else { return fixed }
        return fixed.filter { $0.id == gatewayFilter }
    }

    /// FOS-5: filter controls render on the fleet root only.
    private var showsFilterBar: Bool { gatewayID == nil }

    private var hiddenBotsActive: Bool {
        visibleGateways.flatMap { environment.bots(on: $0.id) }
            .contains { environment.botPresence(for: $0.route) != .unreachable && HiddenBotActivity.hasSignal($0) }
    }

    // MARK: Sections — per-gateway grouping with outage states

    /// Roster sections (bots + outages) for the visible gateways.
    private var snapshotSections: [RosterSection] {
        guard let snapshot = environment.rosterSnapshot else { return [] }
        let visibleIDs = Set(visibleGateways.map(\.id))
        return Self.sections(from: snapshot, cachedBots: environment.cachedBotsByGateway)
            .filter { visibleIDs.contains($0.gateway.id) }
    }

    /// FOS-5: healthy zero-bot gateways that still host Groups get a
    /// synthetic section so a Groups (or All) scope never hides them.
    /// (Outage gateways always have a section already; a `.loaded` zero-bot
    /// gateway is the case this adds.)
    private var collection: [RosterSection] {
        var result = snapshotSections
        guard scope != .bots else { return result }
        let present = Set(result.map(\.gateway.id))
        for gateway in visibleGateways where !present.contains(gateway.id) {
            if !environment.rooms(for: gateway.id).isEmpty {
                result.append(RosterSection(gateway: gateway, bots: [], outage: nil))
            }
        }
        return result
    }

    private var renderedBotsExist: Bool {
        guard scope != .groups else { return false }
        return snapshotSections.contains { !filteredRows(for: $0).isEmpty }
    }

    private var renderedRoomsExist: Bool {
        guard scope != .bots else { return false }
        return visibleGateways.contains { !filteredRooms(for: $0).isEmpty }
    }

    public var body: some View {
        Group {
            if environment.rosterSnapshot == nil {
                refreshing
            } else if environment.gateways.isEmpty {
                emptyFleet
            } else if !renderedBotsExist && !renderedRoomsExist {
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
                            // FOS-5 (SPEC §9): user-facing "Group"; room
                            // stays the internal identity term.
                            Label("Create Group — \(gateway.displayName)", systemImage: "person.3")
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
        .searchable(text: $searchText, prompt: "Bots, groups, gateways")
        .task {
            // Re-render from the latest snapshot on entry (idempotent).
            if environment.rosterSnapshot == nil {
                await environment.refreshRoster()
            }
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.roster")
    }

    private var rosterList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FleetTheme.spacingLg, pinnedViews: []) {
                if showsFilterBar {
                    filterBar
                }
                // FOS-5: ONE fleet-wide Active Now preview above the groups
                // (the per-gateway strips are retired — SPEC §9).
                if scope != .groups {
                    fleetActiveNowPreview
                }
                ForEach(collection) { section in
                    rosterSection(section)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingMd)
        }
        .background(FleetTheme.background)
    }

    /// FOS-5 (SPEC §9): All gateways filter + All / Bots / Groups scope.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Picker("Scope", selection: $scope) {
                Text("All").tag(BotRosterPresentation.Scope.all)
                Text("Bots").tag(BotRosterPresentation.Scope.bots)
                Text("Groups").tag(BotRosterPresentation.Scope.groups)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("fleet.roster.scope")
            Picker("Gateways", selection: $gatewayFilter) {
                Text("All Gateways").tag(Optional<GatewayID>.none)
                ForEach(environment.gateways) { gateway in
                    Text(gateway.displayName).tag(Optional(gateway.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("fleet.roster.gateway-filter")
        }
    }

    // MARK: Fleet-wide Active Now (SPEC §7 execution definition)

    /// Live-signal bots across every VISIBLE gateway (never fabricated;
    /// `isActiveNow` admits working/thinking/using tool only).
    private var fleetActiveBots: [FleetBot] {
        var out: [FleetBot] = []
        for section in snapshotSections where section.outage == nil {
            let label = section.gateway.displayName
            let rows = BotRosterPresentation.filter(
                BotRosterPresentation.order(section.bots),
                query: searchText,
                gatewayLabel: { _ in label },
                revealingHidden: revealingHidden
            )
            out += rows.filter(BotRosterPresentation.isActiveNow)
        }
        return out
    }

    /// One fleet-wide Active Now preview. Provenance (gateway) is always
    /// displayed here — SPEC §9 row-density rule for fleet-wide surfaces.
    @ViewBuilder
    private var fleetActiveNowPreview: some View {
        let active = fleetActiveBots
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
                                        .fill(FleetTheme.statusExecuting)
                                        .frame(width: 8, height: 8)
                                    Text("\(BotRosterPresentation.displayTitle(for: bot)) · \(gatewayLabel(for: bot)) · \(activeStateText(bot))")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(FleetTheme.textPrimary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, FleetTheme.spacingSm)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(FleetTheme.surfaceElevated))
                                .overlay(Capsule().strokeBorder(FleetTheme.statusExecuting.opacity(0.4), lineWidth: 1))
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

    private func gatewayLabel(for bot: FleetBot) -> String {
        environment.gateway(for: bot.route.gatewayID)?.displayName ?? bot.route.gatewayID.rawValue
    }

    /// §7 execution labels only — the same states that admit a bot into
    /// the preview. Waiting/needs-attention never render here.
    private func activeStateText(_ bot: FleetBot) -> String {
        switch bot.activity {
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .usingTool: return "Using tool"
        default: return "Active"
        }
    }

    // MARK: Per-gateway sections

    private func rosterSection(_ section: RosterSection) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            gatewayHeader(section)

            if let (status, detail) = section.outage {
                outageRow(gateway: section.gateway, status: status, detail: detail)
                // Ghost rows: a failed refresh still shows the CACHED bots
                // (identity retained, dimmed) — never a same-name twin.
                // FOS-5: search applies to the ghost branch equally, and
                // the PORTRAIT dims — not the text.
                let ghosts = filteredGhosts(for: section)
                if !ghosts.isEmpty {
                    Text("Last known bots")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    ForEach(ghosts) { bot in
                        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                            BotRowView(
                                management: environment.botManagement,
                                bot: bot,
                                presence: .unreachable,
                                anchor: BotRosterPresentation.activityAnchor(for: bot),
                                duplicateLabel: fleetDuplicateLabels[bot.route],
                                dim: .portrait
                            )
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.roster.row.\(bot.route.id)")
                    }
                }
            } else {
                if scope != .groups {
                    botGroups(for: section)
                }
                if scope != .bots {
                    roomsGroup(for: section.gateway)
                }
            }
        }
    }

    /// Search + hidden rules applied to a section's cached ghost bots.
    private func filteredGhosts(for section: RosterSection) -> [FleetBot] {
        let label = section.gateway.displayName
        return BotRosterPresentation.filter(
            BotRosterPresentation.order(section.bots),
            query: searchText,
            gatewayLabel: { _ in label },
            revealingHidden: revealingHidden
        )
    }

    /// Search-filtered visible rows for a healthy section.
    private func filteredRows(for section: RosterSection) -> [FleetBot] {
        let label = section.gateway.displayName
        return BotRosterPresentation.filter(
            BotRosterPresentation.order(section.bots),
            query: searchText,
            gatewayLabel: { _ in label },
            revealingHidden: revealingHidden
        )
    }

    /// FOS-5 (SPEC §9): duplicate-name disambiguation over the WHOLE fleet
    /// — live rows AND offline ghosts — so the same display title on two
    /// machines is labeled even when one is a ghost.
    private var fleetDuplicateLabels: [Route: String] {
        var bots: [FleetBot] = []
        for section in snapshotSections {
            bots += BotRosterPresentation.visible(section.bots, revealingHidden: revealingHidden)
        }
        return BotRosterPresentation.duplicateNameRoutes(bots) { id in
            environment.gateway(for: id)?.displayName ?? id.rawValue
        }
    }

    /// User-section blocks (D10): registry order; each block a header + rows;
    /// unassigned last with NO fabricated header; no sections → plain rows.
    private func botGroups(for section: RosterSection) -> some View {
        let registry = environment.botManagement.sectionsByGateway[section.gateway.id] ?? []
        let gatewayLabel = section.gateway.displayName
        let rows = filteredRows(for: section)
        return VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            if BotSectionRegistry.rendersSections(registry) {
                let blocks = BotSectionRegistry.split(
                    rows,
                    sectionID: { $0.botModeMetadata?.sectionID },
                    sections: registry
                )
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if !block.isUnassigned {
                        sectionHeader(block: block, gateway: section.gateway, rowCount: block.rows.count)
                    }
                    if !block.isUnassigned && isCollapsed(block, gateway: section.gateway) {
                        // Slice 8: honest collapsed affordance — name the
                        /// count so a collapsed section never reads as empty.
                        Text(block.rows.isEmpty ? "No bots" : "\(block.rows.count) bot\(block.rows.count == 1 ? "" : "s")")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .padding(.leading, FleetTheme.spacingLg)
                            .accessibilityIdentifier("fleet.roster.section-count.\(block.id ?? "")")
                    } else {
                        ForEach(block.rows) { bot in
                            botRow(bot, gatewayLabel: gatewayLabel)
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
                    botRow(bot, gatewayLabel: gatewayLabel)
                }
            }
        }
    }

    /// Slice 8 → FOS-5: tappable section header — tap toggles collapse.
    /// Label names the state ("Collapse Research" / "Expand Research") so it
    /// is never color- or chevron-only. Skipped while searching (all
    /// expanded).
    private func sectionHeader(block: SectionBlock<FleetBot>, gateway: FleetGateway, rowCount: Int) -> some View {
        let collapsed = isCollapsed(block, gateway: gateway)
        return Button {
            withAnimation {
                if collapsed {
                    collapsedSections.remove(Self.collapseKey(gateway.id, block.id ?? ""))
                } else if let id = block.id {
                    collapsedSections.insert(Self.collapseKey(gateway.id, id))
                }
            }
        } label: {
            SectionHeader(title: collapsed ? "\(block.name) — \(rowCount)" : block.name)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fleet.roster.section.\(block.id ?? "")")
        .accessibilityLabel(collapsed ? "Expand \(block.name)" : "Collapse \(block.name)")
    }

    /// FOS-5 (SPEC §9): collapse state is keyed (GatewayID, SectionID) —
    /// section ids are unique only inside their own gateway's registry.
    static func collapseKey(_ gatewayID: GatewayID, _ sectionID: String) -> String {
        "\(gatewayID.rawValue)|\(sectionID)"
    }

    private func isCollapsed(_ block: SectionBlock<FleetBot>, gateway: FleetGateway) -> Bool {
        guard let id = block.id else { return false }
        return searchText.isEmpty && collapsedSections.contains(Self.collapseKey(gateway.id, id))
    }

    @ViewBuilder
    private func botRow(_ bot: FleetBot, gatewayLabel: String) -> some View {
        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
            BotRowView(
                management: environment.botManagement,
                bot: bot,
                presence: environment.botPresence(for: bot.route),
                anchor: BotRosterPresentation.activityAnchor(for: bot),
                duplicateLabel: fleetDuplicateLabels[bot.route],
                dim: bot.botModeMetadata?.hidden == true ? .row : .none
            )
        }
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.roster.row.\(bot.route.id)")
    }

    /// Groups (FOS-5 terminology; internal identity stays "room"): rows
    /// from the room union (hosted + desktop legacy).
    @ViewBuilder
    private func roomsGroup(for gateway: FleetGateway) -> some View {
        let visible = filteredRooms(for: gateway)
        if !visible.isEmpty {
            SectionHeader(title: "Groups")
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

    private func filteredRooms(for gateway: FleetGateway) -> [FleetRoom] {
        let rooms = environment.rooms(for: gateway.id)
        guard !searchText.isEmpty else { return rooms }
        return rooms.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
        // FOS-6: outage state is a coverage notice (SPEC §18 "Coverage/
        // status banner"), not a card.
        FleetNoticeBar(
            "\(statusText(status)) — \(detailNonEmpty(detail, status: status))",
            systemImage: "wifi.slash",
            tone: .warning,
            id: "fleet.roster.outage.\(gateway.id.rawValue)"
        )
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

/// How a bot row dims: ghosts dim ONLY the portrait (identity stays
/// readable — SPEC §9); revealed hidden bots dim the whole row (existing
/// presentation signal).
enum BotRowDim {
    case none
    case portrait
    case row
}

/// A bot row (slice 2 anatomy): avatar | title (+dup label) + preview/time |
/// status pill. Ghost rows dim the portrait, not the text; hidden-revealed
/// rows dim the whole row.
struct BotRowView: View {
    let management: BotManagementController
    let bot: FleetBot
    let presence: BotPresence
    let anchor: BotRosterPresentation.ActivityAnchor
    let duplicateLabel: String?
    var dim: BotRowDim = .none
    /// FOS-6: optional model · provider line (gateway-scoped collection).
    var modelProviderText: String? = nil
    /// FOS-6: optional own-gateway-process badge (gateway-scoped collection).
    var showsGatewayRunningBadge = false

    var body: some View {
        // FOS-6: operational row — no card chrome, hairline separator
        // (SPEC §18 "Operational row").
        FleetListRow {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(bot: bot, management: management)
                    .opacity(dim == .portrait ? 0.4 : (dim == .row ? 0.4 : 1))
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
                    if let modelProviderText {
                        Text(modelProviderText)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                    }
                    if showsGatewayRunningBadge && bot.gatewayRunning {
                        GatewayRunningBadge(isRunning: true)
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
            .opacity(dim == .row ? 0.55 : 1)
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

/// A Group row (internal identity: room): name, member/preview line,
/// provenance label for legacy rows, read-only badge only from real
/// capability state.
struct RoomRowView: View {
    let room: FleetRoom

    var body: some View {
        // FOS-6: operational row (SPEC §18).
        FleetListRow {
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
                                .accessibilityLabel("Managed by Hermes Desktop · read only")
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
                        // FOS-5 (SPEC §9): legacy rows say exactly this.
                        Text("Managed by Hermes Desktop · Read only")
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

/// Composite group avatar: up to 4 member initials in a 2×2 grid.
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
                            .font(.system(size: 9, weight: .bold, design: .default))
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
