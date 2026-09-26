import SwiftUI
import FleetCore

// MARK: - Column section

/// One status column: header (name + count) + horizontal lane of cards.
/// Build 41: cards are actionable — context menu offers status moves, tap
/// opens detail (or toggles selection in select mode).
struct KanbanColumnSection: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let title: String
    let cards: [KanbanCard]
    let selectMode: Bool
    let isSelected: (String) -> Bool
    let onToggleSelect: ((String) -> Void)?
    let onMove: ((String, String) -> Void)?
    let onCardTap: ((KanbanCard) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            // FOS-7 (SPEC §14): sentence-case column label + mono count
            // chip + a hairline divider structuring the lane. The column
            // title itself is DATA (UI-test landmark).
            HStack(spacing: FleetTheme.spacingSm) {
                Text(title.capitalized)
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textSecondary)
                Text("\(cards.count)")
                    .font(FleetTheme.monoCaptionFont.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                    // V4 motion: live board counts settle instead of swap.
                    .contentTransition(.numericText())
                    .padding(.horizontal, FleetTheme.spacingSm)
                    .padding(.vertical, 2)
                    .background(theme.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title.capitalized), \(cards.count) cards")
            // V4 motion: animation context for the count chip's numeric
            // transition (fires when the live snapshot re-counts the lane).
            .animation(.easeOut(duration: 0.18), value: cards.count)
            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)

            if cards.isEmpty {
                Text("No cards")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FleetTheme.spacingSm)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: FleetTheme.spacingMd) {
                        ForEach(cards) { card in
                            KanbanCardView(
                                card: card,
                                selectMode: selectMode,
                                isSelected: isSelected(card.id),
                                onMove: onMove,
                                onTap: onCardTap,
                                onToggleSelect: onToggleSelect)
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

/// One task card. Build 41: informational surface + interaction entry —
/// context menu (status moves) and tap (detail / select). The card itself
/// is never a direct mutation control; every mutation routes through the
/// view model with a server round-trip.
struct KanbanCardView: View {
    @Environment(\.fleetTheme) private var theme
    let card: KanbanCard
    let selectMode: Bool
    let isSelected: Bool
    let onMove: ((String, String) -> Void)?
    let onTap: ((KanbanCard) -> Void)?
    let onToggleSelect: ((String) -> Void)?

    init(
        card: KanbanCard,
        selectMode: Bool = false,
        isSelected: Bool = false,
        onMove: ((String, String) -> Void)? = nil,
        onTap: ((KanbanCard) -> Void)? = nil,
        onToggleSelect: ((String) -> Void)? = nil
    ) {
        self.card = card
        self.selectMode = selectMode
        self.isSelected = isSelected
        self.onMove = onMove
        self.onTap = onTap
        self.onToggleSelect = onToggleSelect
    }

    var body: some View {
        // A Button keeps children addressable in the AX tree while the card
        // remains ONE focusable element (bend-slice-3 lesson: container
        // `.accessibilityIdentifier`/`.ignore` erases descendant ids).
        Button {
            if selectMode {
                onToggleSelect?(card.id)
            } else {
                onTap?(card)
            }
        } label: {
            FleetCard {
                cardContent
            }
            .opacity(selectMode && !isSelected ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onMove {
                ForEach(KanbanStatus.settable.filter { $0 != card.status }, id: \.self) { status in
                    Button {
                        onMove(card.id, status)
                    } label: {
                        Label("Move to \(status.capitalized)", systemImage: statusIcon(status))
                    }
                }
                if card.status == "running" {
                    Button(role: .destructive) {
                        onMove(card.id, "todo")
                    } label: {
                        Label("Reclaim to Todo", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }
        }
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens card details")
        .accessibilityIdentifier("kanban.card.\(card.id)")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            if selectMode {
                HStack(spacing: FleetTheme.spacingSm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? theme.highlight : theme.textMuted)
                    Text(card.title)
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                }
            } else {
                Text(card.title)
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
            }
            if let assignee = card.assignee {
                Label(assignee, systemImage: "person.crop.circle")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            if let summary = card.latestSummary, !summary.isEmpty {
                Text(summary)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
            }
            HStack(spacing: FleetTheme.spacingSm) {
                if let createdAt = card.createdAt {
                    // V3: relative age is telemetry — mono caption.
                    Text(Self.relativeAge(createdAt))
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if let priority = card.priority, priority != 0 {
                    Text("P\(priority)")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                }
                // V3: the card ID is machine data — mono, muted.
                Text(card.id)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(width: 220, alignment: .leading)
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "triage": "tray"
        case "todo": "circle"
        case "scheduled": "clock"
        case "ready": "play.circle"
        case "blocked": "minus.circle"
        case "review": "eye.circle"
        case "done": "checkmark.circle"
        default: "circle"
        }
    }

    private var accessibilityDescription: String {
        var parts = [card.title]
        parts.append("status \(card.status)")
        if let assignee = card.assignee { parts.append("assigned to \(assignee)") }
        parts.append("double tap to open details")
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
