import SwiftUI
import FleetCore
import FleetPersistence

/// FOS-4 (t_2f5bf49a, SPEC §7/§17) — the TRUTHFUL Fleet Home.
///
/// Composition (in first-viewport priority order):
/// 1. compact 2×2 glance strip (connected n/m · known Bots · Active ·
///    needs-you) obeying COVERAGE TRUTH — unknown/incomplete never renders
///    zero, `0/0` renders "No gateways";
/// 2. Needs You — ALREADY-OBSERVED authoritative items only (classified
///    gateway auth/config failures + attention observed in OPENED rooms),
///    deduped, one expanded preview + count, previews NAVIGATE (no approve
///    buttons here), coverage caveat when incomplete ("N known items");
/// 3. Active Now — REAL execution only (working/thinking/usingTool from
///    actual roster signals); a worker heartbeat renders "Recent worker
///    activity", never Thinking; when the sources cannot provide
///    fleet-complete activity the honest coverage copy renders — never
///    `bots.prefix(10)` disguised as Active;
/// 4. Continue — this phone's recent-open index (≤2 rows, exact
///    source-qualified destinations, never same-name substitution);
/// 5. Gateways — compact rows (name, connection state, known bot count +
///    freshness) into Gateway Detail; exceptions first; no raw endpoints;
/// 6. Connection activity — last, ≤3 observations, "Connection summary"
///    destination (FleetActivityView; HealthDashboardView demoted below it).
///
/// Cost contract (SPEC §17): the view contains NO networking — roster
/// observation happens through the app-seam coordinator
/// (`refreshSummaryIfDue`), zero `session.list` per bot and zero
/// `groups.state` per room issue from Home.
public struct FleetDashboardView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private let environment: AppEnvironment

    @State private var now = Date()

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: derived truth (pure reads of observable state — no I/O here)

    private var hasGateways: Bool { !environment.gateways.isEmpty }
    private var rosterLoaded: Bool { environment.rosterSnapshot != nil }

    private var connectedCount: Int {
        environment.gateways.filter { environment.connectionStates[$0.id] == .connected }.count
    }

    /// Union inventory (SPEC §7 Known Bots): live successful roster PLUS
    /// retained last-known snapshots for failed sources. nil = not loaded.
    private var knownBotCount: Int? {
        guard let snapshot = environment.rosterSnapshot else { return nil }
        var routes = Set<Route>()
        for gateway in environment.gateways {
            if case .loaded = snapshot.outcome(for: gateway.id) {
                routes.formUnion(snapshot.bots(on: gateway.id).map(\.route))
            } else if let cached = environment.cachedBotsByGateway[gateway.id] {
                routes.formUnion(cached.map(\.route))
            }
        }
        return routes.count
    }

    private var executingBots: [FleetBot] {
        guard let snapshot = environment.rosterSnapshot else { return [] }
        return snapshot.roster.allBots.filter {
            $0.activity == .working || $0.activity == .thinking || $0.activity == .usingTool
        }
    }

    /// Recent worker heartbeats (SPEC §7 freshness: 90s window) — labeled
    /// "Recent worker activity", NEVER counted as executing.
    private var recentWorkerBots: [FleetBot] {
        guard let snapshot = environment.rosterSnapshot else { return [] }
        let cutoff = now.addingTimeInterval(-90)
        return snapshot.roster.allBots.filter { bot in
            bot.activity != .working && bot.activity != .thinking && bot.activity != .usingTool
                && bot.workerSession != nil
                && Date(timeIntervalSince1970: bot.workerSession!.lastActive) > cutoff
        }
    }

    private var attentionItems: [FleetAttentionItem] { environment.attentionItems() }
    private var attentionCoverageComplete: Bool { environment.attentionCoverage().allGatewaysClassified }

    // MARK: Live Ops v1 (additive — mission "mobile control room" upgrade)

    private var liveOpsSnapshot: LiveOpsSnapshot? { environment.liveOps.snapshot }
    /// Live Ops is the primary concept once at least one gateway has ever
    /// reported it; otherwise Home falls back to the existing honest
    /// roster-derived Active Now section unchanged.
    private var liveOpsAvailable: Bool {
        guard let liveOpsSnapshot else { return false }
        return liveOpsSnapshot.gateways.contains(where: \.hasEverReported)
    }
    private var liveOperations: [LiveOperation] {
        (liveOpsSnapshot?.allOperations ?? []).sorted { $0.startedAt > $1.startedAt }
    }
    private var liveOpsAttentionItems: [LiveOpsAttentionItem] { environment.liveOps.attentionItems }

    private var continueEntries: [FleetContinueIndexStore.Entry] {
        Array(environment.continueIndex.entries().prefix(2))
    }

    // MARK: body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                if hasGateways {
                    glanceStrip
                    coverageLine
                    needsYouSection
                    if liveOpsAvailable {
                        liveOperationsSection
                    } else {
                        liveReportingSetupSection
                        activeSection
                    }
                    continueSection
                    gatewaysSection
                    connectionActivitySection
                } else {
                    emptyFleetState
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingXl)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Fleet")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("fleet.dashboard")
        .refreshable {
            // One coalesced bounded summary refresh (joins in-flight work).
            await environment.refreshSummaryIfDue()
        }
        .task {
            // Home entry: at most one due roster refresh per gateway,
            // bounded by the roster service (≤3 in flight, 10s deadline).
            await environment.refreshSummaryIfDue()
            await environment.refreshHealthStats()
            // Keep relative timestamps fresh while visible; cheap 60s tick.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task {
            // Live Ops v1: Home is one polling context. Registered for the
            // lifetime of this `.task` — cancelled the instant Home
            // disappears, so a backgrounded/dismissed dashboard never keeps
            // the fleet-wide poll loop running.
            environment.liveOps.beginObserving(.home)
            defer { environment.liveOps.endObserving(.home) }
            try? await Task.sleep(for: .seconds(3600 * 24))
        }
    }

    // MARK: 1. Glance strip (compact 2×2 facts, no bordered tiles)

    private var glanceStrip: some View {
        // FOS-6: the shared component (stacks one-per-line at
        // accessibility type sizes). Identifiers unchanged. No
        // container-level id (repo lesson).
        FleetGlanceStrip(
            a: FleetGlanceFact(
                value: "\(connectedCount)/\(environment.gateways.count)",
                label: "Connected",
                id: "fleet.dashboard.glance.connected"),
            b: FleetGlanceFact(
                value: knownBotCount.map { "\($0)" } ?? "…",
                label: "Known Bots",
                id: "fleet.dashboard.glance.bots"),
            c: FleetGlanceFact(
                value: activeGlanceValue,
                label: "Active",
                id: "fleet.dashboard.glance.active"),
            d: FleetGlanceFact(
                value: needsYouGlanceValue,
                label: needsYouGlanceLabel,
                id: "fleet.dashboard.glance.needsYou")
        )
    }

    /// Active glance VALUE: Live Ops' own active count (working/starting/
    /// waiting) when at least one gateway has ever reported it — a truer,
    /// session-level signal than the roster's per-bot activity flag; falls
    /// back to the existing roster-derived count otherwise. `.partial`
    /// coverage never renders zero (SPEC §7).
    private var activeGlanceValue: String {
        if liveOpsAvailable, let count = liveOpsSnapshot?.activeCount {
            return count.value.map { "\($0)" } ?? "—"
        }
        guard rosterLoaded else { return "—" }
        let count = executingBots.count
        return count > 0 ? "\(count)" : "—"
    }

    private var needsYouGlanceValue: String {
        let count = attentionItems.count + liveOpsAttentionItems.count
        if count > 0 { return "\(count)" }
        return attentionCoverageComplete ? "0" : "—"
    }

    /// Coverage qualifier rides the LABEL: "Needing you" only under
    /// complete coverage; otherwise "Known attention items" (SPEC §7 —
    /// an incomplete inbox never reads as complete).
    private var needsYouGlanceLabel: String {
        guard attentionItems.count > 0 else {
            return attentionCoverageComplete ? "Attention" : "Attention"
        }
        return attentionCoverageComplete ? "Needing you" : "Known attention items"
    }

    /// Coverage line under the strip: what was checked, when, and what
    /// could not be (partial outage never reads as zero).
    private var coverageLine: some View {
        Text(coverageText)
            .font(FleetTheme.secondaryFont)
            .foregroundStyle(theme.textSecondary)
            .accessibilityIdentifier("fleet.dashboard.coverage")
    }

    private var coverageText: String {
        guard let snapshot = environment.rosterSnapshot else {
            return hasGateways ? "Checking your gateways…" : ""
        }
        let failed = environment.gateways.filter {
            if case .failed = snapshot.outcome(for: $0.id) { return true }
            return false
        }
        var parts: [String] = []
        if let observed = environment.rosterObservedAt {
            parts.append("Last checked \(FleetDashboardFormatting.relativeTime(from: observed, since: now))")
        }
        if failed.isEmpty {
            if !rosterLoaded { parts.append("activity not available from these gateways") }
        } else {
            let names = failed.map(\.displayName).joined(separator: ", ")
            parts.append("unavailable from this phone: \(names)")
        }
        if let caveat = environment.liveOps.coverageCaveat {
            parts.append(caveat)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 2. Needs You (observed items only; previews navigate)

    @ViewBuilder
    private var needsYouSection: some View {
        let totalCount = attentionItems.count + liveOpsAttentionItems.count
        if totalCount > 0 {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                needsYouHeader
                // Live Ops rows lead (an approval blocking a running agent is
                // the most time-sensitive class of "needs you"), then the
                // existing observed items — one expanded preview + count
                // (SPEC §7 first-viewport rule); every item navigates/acts.
                ForEach(liveOpsAttentionItems.prefix(3)) { item in
                    liveOpsAttentionRow(item)
                }
                let remainingSlots = max(0, 3 - liveOpsAttentionItems.count)
                ForEach(attentionItems.prefix(remainingSlots)) { item in
                    attentionRow(item)
                }
                let shown = min(liveOpsAttentionItems.count, 3) + min(attentionItems.count, remainingSlots)
                if totalCount > shown {
                    Text("+ \(totalCount - shown) more")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                }
                if !attentionCoverageComplete {
                    Text("\(totalCount) known item\(totalCount == 1 ? "" : "s") — more may be pending elsewhere")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.dashboard.needsYou.caveat")
                }
            }
        }
    }

    /// A Live Ops attention row: a pending approval renders inline
    /// Approve/Deny (Approve is biometric-gated, same posture as the
    /// conversation approval banner); a waiting session with no known
    /// approval renders "Waiting for you" and navigates to Operation Detail.
    private func liveOpsAttentionRow(_ item: LiveOpsAttentionItem) -> some View {
        let rowID = "fleet.dashboard.needsYou.liveOps.\(item.operation.id.gatewayID.rawValue).\(sanitized(item.operation.id.runtimeSessionID))"
        return Group {
            if let approval = item.pendingApproval {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(FleetTheme.statusNeedsIntervention)
                            .accessibilityHidden(true)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(operationTitle(item.operation)) · \(gatewayName(item.operation.id.gatewayID))")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Approval needed · \(approval.command)")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let message = environment.liveOps.actionErrors[approval.requestID] {
                                Text(message)
                                    .font(FleetTheme.secondaryFont)
                                    .foregroundStyle(FleetTheme.statusDegraded)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let busy = environment.liveOps.resolvingRequestIDs.contains(approval.requestID)
                    HStack(spacing: FleetTheme.spacingSm) {
                        Spacer(minLength: 0)
                        Button("Deny") { Task { await environment.liveOps.deny(item) } }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                            .accessibilityIdentifier("\(rowID).deny")
                            .frame(minWidth: 88, minHeight: 44)
                            .fixedSize()
                        Button("Approve") { Task { await environment.liveOps.approve(item) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                            .accessibilityIdentifier("\(rowID).approve")
                            .frame(minWidth: 104, minHeight: 44)
                            .fixedSize()
                    }
                }
            } else {
                NavigationLink {
                    LiveOperationDetailView(environment: environment, operation: item.operation)
                } label: {
                    HStack(spacing: FleetTheme.spacingMd) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(FleetTheme.statusNeutral)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(operationTitle(item.operation)) · \(gatewayName(item.operation.id.gatewayID))")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text("Waiting for you")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text("Review")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.highlight)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier(rowID)
            }
        }
    }

    private func operationTitle(_ operation: LiveOperation) -> String {
        operation.title.isEmpty ? "Untitled session" : operation.title
    }

    private func gatewayName(_ id: GatewayID) -> String {
        environment.gateway(for: id)?.displayName ?? id.rawValue
    }

    private var needsYouHeader: some View {
        Text("Needs You")
            .font(FleetTheme.sectionHeaderFont)
            .foregroundStyle(theme.textSecondary)
            .accessibilityIdentifier("fleet.dashboard.needsYou.header")
    }

    private func attentionRow(_ item: FleetAttentionItem) -> some View {
        NavigationLink(value: destination(for: item)) {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: attentionIcon(item.kind))
                    .foregroundStyle(theme.highlight)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("Review")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.highlight)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.dashboard.needsYou.row.\(sanitized(item.id))")
    }

    private func destination(for item: FleetAttentionItem) -> FleetScreen {
        switch item.destination {
        case .gatewayAuthentication(let id), .gatewayConnection(let id):
            return .gatewayConnection(id)
        case .room(let roomID):
            return .room(roomID)
        }
    }

    private func attentionIcon(_ kind: FleetAttentionItem.Kind) -> String {
        switch kind {
        case .gatewayAuthRequired: return "person.crop.circle.badge.exclamationmark"
        case .gatewayConfigProblem: return "wrench.and.screwdriver"
        case .roomApproval: return "hand.raised"
        case .roomRetry: return "arrow.clockwise"
        case .roomDriverBlocked: return "nosign"
        }
    }

    // MARK: 3. Active Now (real execution only)

    private var activeHeader: some View {
        Text("Active Now")
            .font(FleetTheme.sectionHeaderFont)
            .foregroundStyle(theme.textSecondary)
            .accessibilityIdentifier("fleet.dashboard.active.header")
    }

    @ViewBuilder
    private var activeSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            activeHeader
            if !executingBots.isEmpty {
                ForEach(executingBots.prefix(2)) { bot in
                    activeRow(bot)
                }
                if executingBots.count > 2 {
                    Text("+ \(executingBots.count - 2) more")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                }
            } else if !recentWorkerBots.isEmpty {
                // A heartbeat proves recency, not execution (SPEC §7).
                ForEach(recentWorkerBots.prefix(2)) { bot in
                    recentWorkerRow(bot)
                }
            } else {
                Text("Live Bot activity is not available from these gateways.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.dashboard.active.unavailable")
            }
        }
    }

    private func activeRow(_ bot: FleetBot) -> some View {
        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(bot: bot, management: environment.botManagement)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(activeSubtitle(bot))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.dashboard.active.row.\(bot.route.gatewayID.rawValue)#\(bot.route.profileSlug.rawValue)")
    }

    private func activeSubtitle(_ bot: FleetBot) -> String {
        let gatewayName = environment.gateway(for: bot.route.gatewayID)?.displayName
            ?? bot.route.gatewayID.rawValue
        let state: String
        switch bot.activity {
        case .working: state = "Working"
        case .thinking: state = "Thinking"
        case .usingTool: state = "Using tool"
        default: state = "Activity unknown"
        }
        // F1 (dogfood corrective pass): the Active Now subtitle is a
        // user-facing latest-session surface — derive it through the shared
        // presentation-only sanitizer. The stored `SessionSummary.preview` is
        // never mutated and never rendered raw.
        if let raw = bot.latestSession?.preview ?? bot.latestSession?.title,
           !raw.isEmpty {
            let readable = SessionPreviewText.humanReadable(raw)
            if !readable.isEmpty {
                return "\(state) · \(gatewayName) · \(readable)"
            }
        }
        return "\(state) · \(gatewayName)"
    }

    private func recentWorkerRow(_ bot: FleetBot) -> some View {
        NavigationLink(value: FleetScreen.botDetail(bot.route)) {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(bot: bot, management: environment.botManagement)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Recent worker activity · \(environment.gateway(for: bot.route.gatewayID)?.displayName ?? bot.route.gatewayID.rawValue)")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.dashboard.active.recent.\(bot.route.gatewayID.rawValue)#\(bot.route.profileSlug.rawValue)")
    }

    // MARK: 3b. Live Operations (Live Ops v1 — primary concept when available)

    private var liveOperationsHeader: some View {
        Text("Live Operations")
            .font(FleetTheme.sectionHeaderFont)
            .foregroundStyle(theme.textSecondary)
            .accessibilityIdentifier("fleet.dashboard.liveOps.header")
    }

    private var nonIdleOperations: [LiveOperation] { liveOperations.filter(\.isActive) }
    private var idleOperationCount: Int { liveOperations.count - nonIdleOperations.count }

    @ViewBuilder
    private var liveReportingSetupSection: some View {
        let gateways = environment.liveOps.snapshot?.gateways.filter { $0.reportingSetup != .unknown } ?? []
        if !gateways.isEmpty {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                liveOperationsHeader
                ForEach(gateways) { gateway in
                    reportingStatus(gateway)
                }
            }
        }
    }

    private func reportingStatus(_ gateway: LiveOpsGatewaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            if environment.gateways.count > 1 {
                Text(environment.gateway(for: gateway.gatewayID)?.displayName ?? "Hermes gateway")
                    .font(FleetTheme.secondaryFont)
            }
            LiveOpsReportingStatusView(environment: environment, gatewayID: gateway.gatewayID)
        }
    }

    @ViewBuilder
    private var liveOperationsSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            liveOperationsHeader
            ForEach(environment.liveOps.snapshot?.gateways.filter { $0.reportingSetup != .unknown || $0.observationNote != nil } ?? []) { gateway in
                reportingStatus(gateway)
            }
            if nonIdleOperations.isEmpty && idleOperationCount == 0 {
                Text(liveOpsSnapshot?.gateways.contains(where: { $0.reportingSetup == .required }) == true
                     ? "Set up reporting to see Desktop operations."
                     : "No live operations right now.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.dashboard.liveOps.empty")
            } else {
                ForEach(nonIdleOperations.prefix(4)) { operation in
                    liveOperationCard(operation)
                }
                if idleOperationCount > 0 {
                    Text("\(idleOperationCount) idle session\(idleOperationCount == 1 ? "" : "s")")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.dashboard.liveOps.idleCount")
                }
            }
        }
    }

    private func liveOperationCard(_ operation: LiveOperation) -> some View {
        let stale = environment.liveOps.isStale(operation)
        return NavigationLink {
            LiveOperationDetailView(environment: environment, operation: operation)
        } label: {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                HStack(spacing: FleetTheme.spacingSm) {
                    statusPill(operation, stale: stale)
                    Text(operationTitle(operation))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityHidden(true)
                }
                Text(operationSubtitle(operation, stale: stale))
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                if !operation.preview.isEmpty {
                    Text(operation.preview)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                TimelineView(.periodic(from: operation.startedAt, by: 60)) { _ in
                    Text(operationMetaLine(operation, stale: stale))
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(FleetTheme.spacingMd)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                    .strokeBorder(theme.textMuted.opacity(0.15))
            )
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.dashboard.liveOps.operation.\(operation.id.gatewayID.rawValue)#\(sanitized(operation.id.runtimeSessionID))")
    }

    private func statusPill(_ operation: LiveOperation, stale: Bool) -> some View {
        let (label, color): (String, Color) = {
            if stale { return ("Stale", FleetTheme.statusNeutral) }
            if operation.isDelegating { return ("Delegating", FleetTheme.statusExecuting) }
            switch operation.status {
            case .working: return ("Working", FleetTheme.statusExecuting)
            case .starting: return ("Starting", FleetTheme.statusExecuting)
            case .waiting: return ("Waiting", FleetTheme.statusNeedsIntervention)
            case .idle: return ("Idle", FleetTheme.statusNeutral)
            case .unknown: return ("Unknown", FleetTheme.statusNeutral)
            }
        }()
        return Text(label)
            .font(FleetTheme.monoCaptionFont)
            .foregroundStyle(color)
            .padding(.horizontal, FleetTheme.spacingSm)
            .padding(.vertical, 2)
            .background(FleetTheme.statusPillTint(color), in: Capsule())
    }

    private func operationSubtitle(_ operation: LiveOperation, stale: Bool) -> String {
        let gateway = gatewayName(operation.id.gatewayID)
        let statusWord: String
        switch operation.status {
        case .working: statusWord = "Working"
        case .starting: statusWord = "Starting"
        case .waiting: statusWord = "Waiting"
        case .idle: statusWord = "Idle"
        case .unknown: statusWord = "Unknown"
        }
        let modelPart = operation.model.isEmpty ? "" : " · \(operation.model)"
        let activity = operation.isDelegating ? "Delegating" : statusWord
        let freshness = stale ? "Last known \(activity)" : activity
        return "\(freshness)\(modelPart) · \(gateway)"
    }

    private func operationMetaLine(_ operation: LiveOperation, stale: Bool) -> String {
        var parts: [String] = []
        if let subagents = operation.subagents {
            parts.append("\(subagents.count) subagent\(subagents.count == 1 ? "" : "s")")
        }
        let elapsed = FleetDashboardFormatting.relativeTime(from: operation.startedAt, since: now)
        parts.append(elapsed)
        if stale, let lastReported = environment.liveOps.lastReportedAt(operation) {
            parts.append("Last reported \(FleetDashboardFormatting.relativeTime(from: lastReported, since: now))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 4. Continue (this phone's recent-open index)

    private var continueHeader: some View {
        Text("Continue")
            .font(FleetTheme.sectionHeaderFont)
            .foregroundStyle(theme.textSecondary)
            .accessibilityIdentifier("fleet.dashboard.continue.header")
    }

    @ViewBuilder
    private var continueSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            continueHeader
            let entries = continueEntries
            if entries.isEmpty {
                Text("No recent conversations on this iPhone")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.dashboard.continue.empty")
                // New conversation entry only when a usable target exists
                // (a roster bot). It picks an exact bot, never a name match.
                if let anyBot = environment.rosterSnapshot?.roster.allBots.first {
                    NavigationLink(value: FleetScreen.botDetail(anyBot.route)) {
                        Label("New conversation", systemImage: "square.and.pencil")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.highlight)
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.dashboard.continue.new")
                }
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    continueRow(entry, index: index)
                }
            }
        }
    }

    /// Open the EXACT conversation by its source-qualified identity
    /// (Route + session id / room id) — never a re-search by title.
    private func continueDestination(for entry: FleetContinueIndexStore.Entry) -> FleetScreen? {
        let gatewayID = GatewayID(rawValue: entry.gatewayIDRaw)
        guard environment.gateways.contains(where: { $0.id == gatewayID }) else {
            return nil // removed source never resolves to another gateway
        }
        switch entry.kind {
        case .room:
            guard let provenance = entry.roomProvenance.flatMap({ RoomProvenance(rawValue: $0) }),
                  let key = entry.roomKey else { return nil }
            return .room(FleetRoomID(provenance: provenance, gatewayID: gatewayID, key: key))
        case .ordinaryConversation, .canonicalBotChat:
            guard let profile = entry.routeProfile, let sessionID = entry.sessionID else {
                return nil
            }
            let route = Route(gatewayID: gatewayID, profileSlug: ProfileSlug(rawValue: profile))
            return .conversation(route, sessionID: sessionID, canonical: entry.kind == .canonicalBotChat)
        }
    }

    @ViewBuilder
    private func continueRow(_ entry: FleetContinueIndexStore.Entry, index: Int) -> some View {
        if let destination = continueDestination(for: entry) {
            NavigationLink(value: destination) {
                HStack(spacing: FleetTheme.spacingMd) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                        Text("\(entry.subtitle) · \(FleetDashboardFormatting.relativeTime(from: entry.openedAt, since: now))")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.fleetPressable)
            .accessibilityIdentifier("fleet.dashboard.continue.row.\(index)")
        }
    }

    // MARK: 5. Gateways (compact rows; exceptions first; no endpoints)

    private var gatewaysHeader: some View {
        SectionHeader(title: "Gateways", destination: FleetScreen.gateways, actionTitle: "See all")
            .accessibilityIdentifier("fleet.dashboard.gateways.header")
    }

    private var orderedGateways: [FleetGateway] {
        // Exceptions first (anything not connected/loaded), then stable
        // registration order (SPEC §7 information priority rule 4).
        environment.gateways.partitioned { gateway in
            gatewayIsException(gateway)
        }
    }

    private func gatewayIsException(_ gateway: FleetGateway) -> Bool {
        if let outcome = environment.rosterSnapshot?.outcome(for: gateway.id) {
            if case .failed = outcome { return true }
            if case .loaded = outcome { return environment.connectionStates[gateway.id] != .connected }
        }
        return environment.connectionStates[gateway.id] != .connected
    }

    private var gatewaysSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            gatewaysHeader
            VStack(spacing: FleetTheme.spacingSm) {
                ForEach(orderedGateways) { gateway in
                    gatewayRow(gateway)
                }
            }
            // Build 43: the Gateways tab is retired — Fleet owns gateway
            // management. This is the obvious first-class entry to the FULL
            // registry cockpit (add / edit / pair / connect / remove), not
            // buried behind the section header's "See all" affordance.
            NavigationLink(value: FleetScreen.gateways) {
                Label("Manage Gateways", systemImage: "server.rack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FleetTheme.spacingSm)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("fleet.dashboard.gateways.manage")
        }
    }

    private func gatewayRow(_ gateway: FleetGateway) -> some View {
        NavigationLink(value: FleetScreen.gatewayDetail(gateway.id)) {
            HStack(spacing: FleetTheme.spacingMd) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gateway.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(gatewaySubtitle(gateway))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(gatewayStateLabel(gateway))
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.dashboard.gateway.\(gateway.id.rawValue)")
    }

    /// Connection state label — classified truth, never a guess.
    private func gatewayStateLabel(_ gateway: FleetGateway) -> String {
        switch environment.connectionStates[gateway.id] {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .failed(let status):
            switch status {
            case .authenticationRequired: return "Sign in required"
            case .unsupported: return "Unsupported endpoint"
            case .degraded: return "Degraded"
            default: return "Offline"
            }
        case .disconnected, .idle, nil:
            // The maintained lifecycle may be idle while the LAST roster
            // probe still classified this gateway (SPEC §7: keep the two
            // observations distinguishable; the subtitle carries freshness).
            if let outcome = environment.rosterSnapshot?.outcome(for: gateway.id) {
                if case .failed(let status, _) = outcome {
                    switch status {
                    case .authenticationRequired: return "Sign in required"
                    case .unsupported: return "Unsupported endpoint"
                    case .degraded: return "Degraded"
                    default: return "Offline"
                    }
                }
            }
            return "Not checked"
        }
    }

    /// Known bot count + freshness for the row subtitle.
    private func gatewaySubtitle(_ gateway: FleetGateway) -> String {
        guard let snapshot = environment.rosterSnapshot else { return "Not checked yet" }
        switch snapshot.outcome(for: gateway.id) {
        case .loaded:
            let count = snapshot.bots(on: gateway.id).count
            return count == 0 ? "No Bots reported" : "\(count) Bots"
        case .failed:
            if let cached = environment.cachedBotsByGateway[gateway.id], !cached.isEmpty {
                return "\(cached.count) Bots · last known"
            }
            return "Bot count unavailable"
        case nil:
            return "Not checked"
        }
    }

    // MARK: 6. Connection activity (last; ≤3 observations)

    private var connectionActivitySection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Connection Activity", destination: FleetScreen.activity, actionTitle: "Connection summary")
                .accessibilityIdentifier("fleet.dashboard.activity.header")
            let entries = Array(FleetDashboardFormatting.activityEntries(
                gateways: environment.gateways,
                stats: environment.healthStats
            ).prefix(3))
            if entries.isEmpty {
                Text("No connection activity recorded yet.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.dashboard.activity.empty")
            } else {
                VStack(spacing: FleetTheme.spacingSm) {
                    ForEach(entries) { entry in
                        activityRow(entry)
                    }
                }
            }
        }
    }

    private func activityRow(_ entry: FleetDashboardFormatting.ActivityEntry) -> some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: entry.icon)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            Text(entry.text)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
            Spacer()
            if let at = entry.at {
                Text(FleetDashboardFormatting.relativeTime(from: at, since: now))
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.dashboard.activity.row.\(entry.id)")
    }

    // MARK: Empty fleet (no registered gateway)

    private var emptyFleetState: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            FleetGlanceFact(value: "No gateways", label: "Connected", id: "fleet.dashboard.glance.connected")
            Text("Add a Hermes server in Gateways to see your fleet here.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
            NavigationLink(value: FleetScreen.gateways) {
                Label("Add Gateway", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.highlight)
            }
            .buttonStyle(.fleetPressable)
            .accessibilityIdentifier("fleet.dashboard.empty.add")
        }
        // NOTE: no container-level accessibilityIdentifier (see glance strip).
    }

    // MARK: helpers

    private func sanitized(_ id: String) -> String {
        id.replacingOccurrences(of: "|", with: ".")
    }
}

extension Array {
    /// Stable partition (order preserved within each side).
    fileprivate func partitioned(by predicate: (Element) -> Bool) -> [Element] {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if predicate(element) { first.append(element) } else { second.append(element) }
        }
        return first + second
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
