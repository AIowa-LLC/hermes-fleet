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
    @State private var model: KanbanBoardViewModel?

    public init(environment: AppEnvironment) {
        self.environment = environment
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
            let next = KanbanBoardViewModel(watcher: watcher)
            await model?.stop()
            model = next
            await next.start()
        }
        .onDisappear {
            Task { await model?.stop() }
        }
    }

    /// The gateway whose board is shown: the first connected gateway, else
    /// the first registered (single-gateway v1; multi-gateway board picking
    /// is a later phase).
    private var boardGateway: FleetGateway? {
        let connected = environment.gateways.first { gateway in
            if case .connected = environment.connectionStates[gateway.id] ?? .idle {
                return true
            }
            return false
        }
        return connected ?? environment.gateways.first
    }

    private var boardGatewayID: GatewayID? { boardGateway?.id }

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
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(FleetTheme.statusOnline)
                Text("Live")
            case .reconnecting:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(FleetTheme.statusDegraded)
                Text("Reconnecting…")
            case .idle:
                Image(systemName: "pause.circle")
                    .foregroundStyle(FleetTheme.statusOffline)
                Text("Stream idle")
            }
        }
        .font(.system(size: FleetTheme.secondaryFontSize, weight: .semibold))
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
                    .tint(FleetTheme.accentGold)
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
                .font(.system(size: FleetTheme.secondaryFontSize, weight: .semibold))
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
                .font(FleetTheme.sectionHeaderFont)
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
    private func activityStrip(_ model: KanbanBoardViewModel) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Recent Activity")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(FleetTheme.textPrimary)
            ForEach(model.recentEvents.prefix(5)) { event in
                HStack(spacing: FleetTheme.spacingSm) {
                    Circle()
                        .fill(FleetTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("\(event.taskID) · \(event.kind)")
                        .font(FleetTheme.secondaryFont)
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
    let title: String
    let cards: [KanbanCard]

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            HStack(spacing: FleetTheme.spacingSm) {
                Text(title.capitalized)
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(FleetTheme.textPrimary)
                Text("\(cards.count)")
                    .font(.system(size: FleetTheme.secondaryFontSize, weight: .semibold))
                    .foregroundStyle(FleetTheme.textSecondary)
                    .padding(.horizontal, FleetTheme.spacingSm)
                    .padding(.vertical, 2)
                    .background(FleetTheme.surface)
                    .clipShape(Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title.capitalized), \(cards.count) cards")

            if cards.isEmpty {
                Text("No cards")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .opacity(0.6)
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
                        Text(Self.relativeAge(createdAt))
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    Spacer()
                    Text(card.id)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary.opacity(0.7))
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
