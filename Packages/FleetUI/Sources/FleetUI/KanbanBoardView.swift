import SwiftUI
import FleetCore

/// Build 41 — the INTERACTIVE Kanban board.
///
/// Renders the board snapshot as vertically scrolling sections (one per
/// status column), each a horizontal lane of cards. Updates land live: the
/// view model refetches the snapshot when stream events arrive — no manual
/// refresh needed (pull-to-refresh exists as a recovery path).
///
/// Build 41: cards are actionable — tap opens full detail; context menu
/// offers status moves; toolbar hosts create + filters + multi-select bulk
/// mode + orchestration. When the gateway has no board operator the board
/// degrades to the honest read-only presentation (fail closed).
public struct KanbanBoardView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let initialBoard: String?
    @State private var model: KanbanBoardViewModel?
    @State private var showingCreate = false
    @State private var showingFilters = false
    @State private var showingOrchestration = false
    @State private var selectedTaskIDs: Set<String> = []
    @State private var selectMode = false
    @State private var detailCard: KanbanDetailPresentation?

    public init(environment: AppEnvironment, gatewayID: GatewayID, board: String? = nil) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.initialBoard = board
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                emptyGatewaysContent
            } else {
                boardContent
            }
        }
        .background(theme.background)
        .navigationTitle("Kanban")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { kanbanToolbar }
        .sheet(isPresented: $showingCreate) {
            KanbanTaskCreateView(model: model)
        }
        .sheet(isPresented: $showingFilters) {
            KanbanFilterView(model: model)
        }
        .sheet(isPresented: $showingOrchestration) {
            KanbanOrchestrationView(model: model)
        }
        .sheet(item: $detailCard) { presentation in
            KanbanTaskDetailView(
                environment: environment,
                gatewayID: gatewayID,
                taskID: presentation.taskID,
                model: model)
        }
        .task(id: boardGatewayID) {
            // (Re)bind the model whenever the board's source gateway changes
            // (first appear, registry edit, gateway removal).
            guard let gateway = boardGateway else {
                await model?.stop()
                model = nil
                return
            }
            guard let watcher = environment.makeKanbanWatcher(for: gateway) else {
                await model?.stop()
                model = nil
                return
            }
            let boardOperator = environment.makeKanbanOperator(for: gateway)
            let next = KanbanBoardViewModel(
                watcher: watcher,
                boardOperator: boardOperator,
                selectionStore: KanbanBoardSelectionStore(gatewayID: gatewayID))
            await model?.stop()
            model = next
            await next.start(board: initialBoard)
        }
        .onDisappear {
            Task { await model?.stop() }
        }
    }

    private var boardGateway: FleetGateway? {
        environment.gateways.first { $0.id == gatewayID }
    }
    private var boardGatewayID: GatewayID? { boardGateway?.id }

    // MARK: Toolbar (board picker + select + add + menu)

    @ToolbarContentBuilder
    private var kanbanToolbar: some ToolbarContent {
        // t_624b81cd (B1): board picker — client-side selection only.
        ToolbarItem(placement: .navigationBarTrailing) {
            boardPickerMenu
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if let model, model.canMutate, !selectMode {
                Button {
                    showingCreate = true
                } label: {
                    Label("Add Card", systemImage: "plus")
                }
                .accessibilityIdentifier("kanban.board.add")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                if let model, model.canMutate {
                    if selectMode {
                        Button {
                            selectedTaskIDs.removeAll()
                            selectMode = false
                        } label: {
                            Label("Done Selecting", systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("kanban.board.select.done")
                    } else {
                        Button {
                            selectMode = true
                        } label: {
                            Label("Select Cards", systemImage: "checkmark.circle.circle")
                        }
                        .accessibilityIdentifier("kanban.board.select.start")
                    }
                    Button {
                        Task { await model.dispatchNudge() }
                    } label: {
                        Label("Dispatch now", systemImage: "bolt")
                    }
                    .accessibilityIdentifier("kanban.board.dispatch")
                    Button {
                        showingOrchestration = true
                    } label: {
                        Label("Orchestration", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("kanban.board.orchestration")
                }
                Button {
                    showingFilters = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("kanban.board.filters")
            } label: {
                Label("Board menu", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("kanban.board.menu")
        }
    }

    /// Toolbar menu listing gateway boards: checkmark on the displayed
    /// board, "(active)" note on the operator's current board. Hidden until
    /// the boards list loads (single-board gateways look unchanged).
    @ViewBuilder
    private var boardPickerMenu: some View {
        if let model, !model.boards.isEmpty {
            Menu {
                ForEach(model.boards) { board in
                    Button {
                        Task {
                            await model.selectBoard(
                                board.slug == model.selectedBoard ? nil : board.slug)
                        }
                    } label: {
                        if board.slug == model.selectedBoard {
                            Label(board.name, systemImage: "checkmark")
                        } else if board.isCurrent {
                            Text("\(board.name) (active)")
                        } else {
                            Text(board.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: FleetTheme.spacingXs) {
                    Image(systemName: "rectangle.stack")
                    Text(model.displayBoardName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .font(FleetTheme.secondaryFont.weight(.semibold))
                .foregroundStyle(theme.highlight)
                // Compact nav bars overflow trailing items into the system
                // More bucket when the set does not fit; keep the picker
                // narrow so Add Card and the board menu stay on the bar.
                .lineLimit(1)
                .frame(maxWidth: 110)
            }
            .accessibilityIdentifier("fleet.kanban.board.picker")
        }
    }

    // MARK: Board content

    @ViewBuilder
    private var boardContent: some View {
        if let model {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                        if model.isLoading && model.snapshot == nil {
                            loadingContent
                        } else if let snapshot = model.filteredSnapshot {
                            streamBanner(model)
                            noticeBars(model)
                            if snapshot.totalCards == 0 {
                                emptyBoardContent(model)
                            } else {
                                // ONE branch (not an if/else fork): a
                                // LazyVStack keeps its cached children when
                                // the branch STRUCTURE changes — a single
                                // ForEach whose parameters carry the mode
                                // re-diffs correctly.
                                ForEach(snapshot.columns, id: \.self) { column in
                                    KanbanColumnSection(
                                        title: column,
                                        cards: snapshot.cards(in: column),
                                        selectMode: selectMode,
                                        isSelected: { selectedTaskIDs.contains($0) },
                                        onToggleSelect: { id in
                                            if selectedTaskIDs.contains(id) {
                                                selectedTaskIDs.remove(id)
                                            } else {
                                                selectedTaskIDs.insert(id)
                                            }
                                        },
                                        onMove: selectMode ? nil : { id, status in
                                            Task { await model.moveTask(id: id, to: status) }
                                        },
                                        onCardTap: selectMode ? nil : { card in
                                            detailCard = KanbanDetailPresentation(taskID: card.id)
                                        })
                                }
                            }
                        } else if let error = model.errorMessage {
                            errorContent(error, model: model)
                        }
                        if !model.recentEvents.isEmpty && !selectMode {
                            activityStrip(model)
                        }
                    }
                    .padding(FleetTheme.spacingLg)
                }
                .refreshable { await model.refresh() }
                if selectMode && !selectedTaskIDs.isEmpty {
                    bulkActionBar(model)
                        .padding(.horizontal, FleetTheme.spacingLg)
                        .padding(.bottom, FleetTheme.spacingMd)
                }
            }
        } else {
            loadingContent
        }
    }

    /// Mutation/auxiliary outcome banners (hidden in select mode).
    @ViewBuilder
    private func noticeBars(_ model: KanbanBoardViewModel) -> some View {
        if let message = model.mutationErrorMessage {
            FleetNoticeBar(
                message,
                systemImage: "exclamationmark.triangle.fill",
                tone: .error,
                id: "kanban.board.mutation-error",
                actionTitle: "Dismiss",
                actionID: "kanban.board.mutation-error.dismiss",
                action: { model.mutationErrorMessage = nil })
        }
        if let message = model.auxOutcomeMessage {
            FleetNoticeBar(
                message,
                systemImage: "sparkles",
                id: "kanban.board.aux-note",
                actionTitle: "Dismiss",
                actionID: "kanban.board.aux.dismiss",
                action: { model.auxOutcomeMessage = nil })
        }
    }

    /// Bulk action bar: move/unassign/archive the selected set.
    private func bulkActionBar(_ model: KanbanBoardViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Menu {
                ForEach(KanbanStatus.settable, id: \.self) { status in
                    Button(status.capitalized) {
                        Task {
                            await applyBulk(
                                model,
                                KanbanBulkPatch(ids: Array(selectedTaskIDs), status: status))
                        }
                    }
                }
                Button("Unassign") {
                    Task {
                        await applyBulk(
                            model,
                            KanbanBulkPatch(ids: Array(selectedTaskIDs), assignee: ""))
                    }
                }
                Button("Archive", role: .destructive) {
                    Task {
                        await applyBulk(
                            model,
                            KanbanBulkPatch(ids: Array(selectedTaskIDs), archive: true))
                    }
                }
            } label: {
                Label("Move", systemImage: "arrow.right.circle")
            }
            .accessibilityIdentifier("kanban.board.bulk.move")
            Text("\(selectedTaskIDs.count) selected")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button {
                selectedTaskIDs.removeAll()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("kanban.board.bulk.clear")
        }
        .padding(FleetTheme.spacingMd)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusRow, style: .continuous))
    }

    /// Apply a bulk patch and keep only the ids the server did NOT confirm
    /// selected — a partial failure stays retryable instead of being wiped.
    private func applyBulk(_ model: KanbanBoardViewModel, _ patch: KanbanBulkPatch) async {
        let outcomes = await model.bulkUpdate(patch)
        selectedTaskIDs = KanbanBulkSelection.retained(
            selected: selectedTaskIDs, outcomes: outcomes)
    }

    private func streamBanner(_ model: KanbanBoardViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            switch model.streamPhase {
            case .streaming:
                Circle().fill(FleetTheme.statusOnline).frame(width: 7, height: 7)
                Text("Live")
            case .reconnecting:
                Circle().fill(FleetTheme.statusDegraded).frame(width: 7, height: 7)
                Text("Reconnecting…")
            case .idle:
                Circle().fill(theme.textSecondary).frame(width: 7, height: 7)
                Text("Stream idle")
            }
        }
        // FOS-7 (SPEC §14): the stream banner reads as a plain sentence-
        // case status line — semantic status dot, no tracked uppercase.
        .font(FleetTheme.microLabelFont)
        .foregroundStyle(theme.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: model.streamPhase))
        .accessibilityIdentifier("kanban.board.streamBanner")
    }

    private func accessibilityLabel(for phase: KanbanBoardViewModel.StreamPhase) -> String {
        switch phase {
        case .streaming: return "Board is live"
        case .reconnecting: return "Reconnecting to board stream"
        case .idle: return "Board stream is idle"
        }
    }

    // MARK: States

    private var loadingContent: some View {
        // FOS-6: contextual status, not a card.
        HStack(spacing: FleetTheme.spacingMd) {
            ProgressView()
                .tint(theme.highlight)
            Text("Loading board…")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("kanban.board.loading")
    }

    private func emptyBoardContent(_ model: KanbanBoardViewModel) -> some View {
        VStack(spacing: FleetTheme.spacingMd) {
            FleetNoticeBar(
                "No cards on this board yet.",
                systemImage: "rectangle.stack",
                id: "kanban.board.empty")
            if model.canMutate {
                Button {
                    showingCreate = true
                } label: {
                    Label("Add Card", systemImage: "plus")
                        .foregroundStyle(theme.onHighlight)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("kanban.board.empty.add")
            }
        }
    }

    private func errorContent(_ message: String, model: KanbanBoardViewModel) -> some View {
        FleetNoticeBar(
            message,
            systemImage: "exclamationmark.triangle.fill",
            tone: .error,
            id: "kanban.board.error",
            actionTitle: "Retry",
            actionID: "kanban.board.retry",
            action: { Task { await model.refresh() } })
    }

    private var emptyGatewaysContent: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text("No gateways registered.")
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Add a gateway to see its Kanban board.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(FleetTheme.spacingXxl)
        .accessibilityIdentifier("kanban.board.noGateways")
    }

    /// Recent activity strip — the last few change events (task + kind).
    /// V3: uppercase micro-label header + terminal event lines (dot + mono).
    private func activityStrip(_ model: KanbanBoardViewModel) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Recent Activity")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            ForEach(model.recentEvents.prefix(5)) { event in
                HStack(spacing: FleetTheme.spacingSm) {
                    Circle()
                        .fill(theme.highlight)
                        .frame(width: 6, height: 6)
                    Text("\(event.taskID) · \(event.kind)")
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kanban.board.activity")
    }
}

/// Multi-select retention for bulk actions: only ids the server CONFIRMED
/// (`ok: true`) leave the selection. A partially failed batch stays selected
/// so the user can retry exactly the cards that did not move, and an empty
/// outcome list (no operator, or a transport failure) keeps everything —
/// nothing was confirmed applied.
public enum KanbanBulkSelection {
    public static func retained(selected: Set<String>, outcomes: [KanbanBulkOutcome]) -> Set<String> {
        selected.subtracting(outcomes.filter(\.ok).map(\.id))
    }
}

/// Identifiable task-id wrapper for `.sheet(item:)` card detail presentation.
public struct KanbanDetailPresentation: Identifiable, Sendable {
    public let taskID: String
    public var id: String { taskID }
    public init(taskID: String) {
        self.taskID = taskID
    }
}
