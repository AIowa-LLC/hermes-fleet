import SwiftUI
import FleetCore

/// t_3b321b7b — the live read-only Kanban board (Gold Fleet design).
///
/// Renders the board snapshot as vertically scrolling sections (one per
/// status column), each a horizontal lane of cards. Updates land live: the
/// view model refetches the snapshot when stream events arrive — no manual
/// refresh needed (pull-to-refresh exists as a recovery path, not the
/// primary update mechanism).
///
/// READ-ONLY by construction: no create/edit/move/delete affordances, no
/// drag-and-drop, no mutating context menus. Cards are informational
/// surfaces only.
///
/// Empty/error states are honest: no gateways → onboarding hint; fetch
/// failed → the error with a Retry; empty board → says so.
public struct KanbanBoardView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let initialBoard: String?
    @State private var model: KanbanBoardViewModel?

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
        .background(FleetTheme.background)
        .navigationTitle("Kanban")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // t_624b81cd (B1): board picker — client-side selection only.
            // Switching re-targets snapshot + WS; the gateway operator's
            // active-board pointer is never touched (no /boards/{slug}/switch).
            ToolbarItem(placement: .navigationBarTrailing) {
                boardPickerMenu(model: model)
            }
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
            let next = KanbanBoardViewModel(watcher: watcher, selectionStore: KanbanBoardSelectionStore(gatewayID: gatewayID))
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

    // MARK: Board picker (t_624b81cd — B1)

    /// Toolbar menu listing gateway boards: checkmark on the displayed
    /// board, "active" note on the operator's current board. Hidden until
    /// the boards list loads (single-board gateways look unchanged).
    @ViewBuilder
    private func boardPickerMenu(model: KanbanBoardViewModel?) -> some View {
        if let model, !model.boards.isEmpty {
            Menu {
                ForEach(model.boards) { board in
                    Button {
                        Task {
                            await model.selectBoard(
                                board.slug == model.selectedBoard ? nil : board.slug)
                        }
                    } label: {
                        HStack {
                            if board.slug == model.selectedBoard {
                                Label(board.name, systemImage: "checkmark")
                            } else {
                                Text(board.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: FleetTheme.spacingXs) {
                    Image(systemName: "rectangle.stack")
                    Text(model.displayBoardName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                .font(FleetTheme.secondaryFont.weight(.semibold))
                .foregroundStyle(FleetTheme.accent)
            }
            .accessibilityIdentifier("fleet.kanban.board.picker")
        }
    }

    // MARK: Board

    @ViewBuilder
    private var boardContent: some View {
        if let model {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    if model.isLoading && model.snapshot == nil {
                        loadingContent
                    } else if let snapshot = model.snapshot {
                        streamBanner(model)
                        if snapshot.totalCards == 0 {
                            emptyBoardContent
                        } else {
                            ForEach(snapshot.columns, id: \.self) { column in
                                KanbanColumnSection(
                                    title: column,
                                    cards: snapshot.cards(in: column)
                                )
                            }
                        }
                    } else if let error = model.errorMessage {
                        errorContent(error, model: model)
                    }
                    if !model.recentEvents.isEmpty {
                        activityStrip(model)
                    }
                }
                .padding(FleetTheme.spacingLg)
            }
            .refreshable { await model.refresh() }
        } else {
            loadingContent
        }
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
                Circle().fill(FleetTheme.statusOffline).frame(width: 7, height: 7)
                Text("Stream idle")
            }
        }
        // V3: the stream banner reads like a process-table status line —
        // uppercase micro-label voice, semantic status dot (no icon soup).
        .font(FleetTheme.microLabelFont)
        .textCase(.uppercase)
        .tracking(FleetTheme.microLabelTracking)
        .foregroundStyle(FleetTheme.textSecondary)
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
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                ProgressView()
                    .tint(FleetTheme.accent)
                Text("Loading board…")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        }
        .accessibilityIdentifier("kanban.board.loading")
    }

    private var emptyBoardContent: some View {
        FleetCard {
            Text("No cards on this board yet.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
        }
        .accessibilityIdentifier("kanban.board.empty")
    }

    private func errorContent(_ message: String, model: KanbanBoardViewModel) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text(message)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDegraded)
                Button("Retry") {
                    Task { await model.refresh() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(FleetTheme.accent)
            }
        }
        .accessibilityIdentifier("kanban.board.error")
    }

    private var emptyGatewaysContent: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FleetTheme.textSecondary)
            Text("No gateways registered.")
                .font(.body.weight(.semibold))
                .foregroundStyle(FleetTheme.textPrimary)
            Text("Add a gateway to see its Kanban board.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
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
                .textCase(.uppercase)
                .tracking(FleetTheme.microLabelTracking)
                .foregroundStyle(FleetTheme.textSecondary)
            ForEach(model.recentEvents.prefix(5)) { event in
                HStack(spacing: FleetTheme.spacingSm) {
                    Circle()
                        .fill(FleetTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("\(event.taskID) · \(event.kind)")
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kanban.board.activity")
    }
}

// MARK: - Column section

/// One status column: header (name + count) + horizontal lane of cards.
struct KanbanColumnSection: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let title: String
    let cards: [KanbanCard]

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            // V3 showcase: uppercase column label + MONO count chip + a
            // hairline divider structuring the lane (terminal process-table
            // voice). The column title itself is DATA (UI-test landmark) —
            // no forced case on the title text.
            HStack(spacing: FleetTheme.spacingSm) {
                Text(title.capitalized)
                    .font(FleetTheme.sectionHeaderFont)
                    .textCase(.uppercase)
                    .tracking(FleetTheme.microLabelTracking)
                    .foregroundStyle(FleetTheme.textSecondary)
                Text("\(cards.count)")
                    .font(FleetTheme.monoCaptionFont.monospacedDigit())
                    .foregroundStyle(FleetTheme.textSecondary)
                    // V4 motion: live board counts settle instead of swap.
                    .contentTransition(.numericText())
                    .padding(.horizontal, FleetTheme.spacingSm)
                    .padding(.vertical, 2)
                    .background(FleetTheme.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title.capitalized), \(cards.count) cards")
            // V4 motion: animation context for the count chip's numeric
            // transition (fires when the live snapshot re-counts the lane).
            .animation(.easeOut(duration: 0.18), value: cards.count)
            Rectangle()
                .fill(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast))
                .frame(height: 0.5)

            if cards.isEmpty {
                Text("No cards")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FleetTheme.spacingSm)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: FleetTheme.spacingMd) {
                        ForEach(cards) { card in
                            KanbanCardView(card: card)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

// MARK: - Card

/// One read-only task card — a plain informational surface.
struct KanbanCardView: View {
    let card: KanbanCard

    var body: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Text(card.title)
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(2)
                if let assignee = card.assignee {
                    Label(assignee, systemImage: "person.crop.circle")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                }
                if let summary = card.latestSummary, !summary.isEmpty {
                    Text(summary)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(3)
                }
                HStack(spacing: FleetTheme.spacingSm) {
                    if let createdAt = card.createdAt {
                        // V3: relative age is telemetry — mono caption.
                        Text(Self.relativeAge(createdAt))
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    Spacer()
                    // V3: the card ID is machine data — mono, muted.
                    Text(card.id)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(width: 220, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [card.title]
        parts.append("status \(card.status)")
        if let assignee = card.assignee { parts.append("assigned to \(assignee)") }
        return parts.joined(separator: ", ")
    }

    /// Short relative age from the card's creation epoch seconds.
    static func relativeAge(_ createdAt: Double) -> String {
        let interval = Date().timeIntervalSince1970 - createdAt
        if interval < 60 { return "just now" }
        if interval < 3_600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h ago" }
        return "\(Int(interval / 86_400))d ago"
    }
}
