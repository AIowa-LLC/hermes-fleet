import SwiftUI
import FleetCore

/// R9-T3 — live context meter: a thin capsule showing "% full", semantic
/// color by threshold (normal <70% / warn 70–90% / alert >90%), fed by the
/// streamed `session.usage` ticks. Tap opens the breakdown sheet. Absent
/// data renders NOTHING (never a fabricated 0%); a snapshot with no gauge
/// (`hasContextGauge == false`) renders an honest "ctx —" pill.
public struct ContextMeterView: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ConversationToolingViewModel
    /// Called when the meter is tapped (the host presents the breakdown).
    let onTap: () -> Void

    public init(model: ConversationToolingViewModel, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    private var tint: Color {
        switch model.meterLevel {
        case .alert: return FleetTheme.statusDestructive
        case .warn: return FleetTheme.statusNeedsIntervention
        case .normal, nil: return theme.highlight
        }
    }

    private var percentText: String {
        guard let percent = model.usage?.contextPercent else { return "—" }
        return "\(percent)%"
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let usage = model.usage, usage.hasContextGauge {
                    // Thin capsule: 44pt wide track, filled by percent.
                    Capsule()
                        .fill(theme.surfaceElevated)
                        .frame(width: 44, height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                let fraction = CGFloat(
                                    max(0, min(100, usage.contextPercent ?? 0))) / 100
                                Capsule()
                                    .fill(tint)
                                    .frame(width: geo.size.width * fraction)
                            }
                        }
                        .accessibilityHidden(true)
                    Text(percentText)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(tint)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else if model.usage != nil {
                    // Honest no-gauge: the gateway reports no current-window
                    // occupancy (server.py:7542) — "ctx" with an em dash.
                    Image(systemName: "gauge.with.dots.needle.0percent")
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)
                    Text("ctx —")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textMuted)
                } else {
                    Image(systemName: "gauge.with.dots.needle.0percent")
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the context usage breakdown")
        .accessibilityIdentifier("context.meter")
    }

    private var accessibilityLabel: String {
        guard let usage = model.usage else { return "Context usage unknown" }
        guard usage.hasContextGauge else {
            return "Context usage not reported"
        }
        let level: String
        switch model.meterLevel {
        case .alert: level = "critical"
        case .warn: level = "high"
        case .normal, nil: level = "normal"
        }
        return "Context \(usage.contextPercent ?? 0) percent full, \(level)"
    }
}

/// R9-T3 — context breakdown sheet: per-category token rows (UPPERCASE-KEY
/// mono, the Health dashboard pattern) + the usage summary.
public struct ContextBreakdownSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ConversationToolingViewModel

    @Environment(\.dismiss) private var dismiss

    public init(model: ConversationToolingViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.isLoadingBreakdown && model.breakdown == nil {
                    ProgressView("Computing breakdown…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(theme.textSecondary)
                } else if let error = model.contextError, model.breakdown == nil {
                    ContentUnavailableView {
                        Label("Breakdown Unavailable", systemImage: "chart.bar")
                    } description: {
                        Text(error)
                    }
                } else if let breakdown = model.breakdown {
                    list(breakdown)
                } else {
                    ContentUnavailableView {
                        Label("No Breakdown", systemImage: "chart.bar")
                    } description: {
                        Text("Send a message first — the context breakdown needs a built session.")
                    }
                }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .background(theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.highlight)
                        .accessibilityIdentifier("context.breakdown.done")
                }
            }
            .task {
                await model.loadBreakdown()
                await model.refreshUsage()
            }
            .refreshable {
                await model.loadBreakdown()
                await model.refreshUsage()
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("context.breakdown.sheet")
    }

    private func list(_ breakdown: ContextBreakdown) -> some View {
        ScrollView {
            VStack(spacing: FleetTheme.spacingMd) {
                // Summary header: the meter figure + token counts.
                summaryHeader(breakdown)
                if !breakdown.categories.isEmpty {
                    VStack(spacing: FleetTheme.spacingXs) {
                        ForEach(breakdown.categories) { category in
                            categoryRow(category, total: max(breakdown.estimatedTotal, 1))
                        }
                    }
                    .padding(FleetTheme.spacingSm)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
                }
                if let usage = model.usage, usage.calls > 0 {
                    usageFooter(usage)
                }
            }
            .padding(FleetTheme.spacingLg)
        }
    }

    private func summaryHeader(_ breakdown: ContextBreakdown) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("Context")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: FleetTheme.spacingSm) {
                Text("\(breakdown.contextPercent)%")
                    .font(FleetTheme.statFont)
                    .foregroundStyle(tint(for: breakdown.contextPercent))
                    .contentTransition(.numericText())
                Text("\(Self.compact(breakdown.contextUsed)) / \(Self.compact(breakdown.contextMax)) tokens")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
            }
            if !breakdown.model.isEmpty {
                Text(breakdown.model)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("context.breakdown.summary")
    }

    private func categoryRow(_ category: ContextBreakdownCategory, total: Int) -> some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Text(category.label)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text(Self.compact(category.tokens))
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
            Text("\(max(0, min(100, category.tokens * 100 / total)))%")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textMuted)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.label), \(category.tokens) tokens")
        .accessibilityIdentifier("context.breakdown.row.\(category.id)")
    }

    private func usageFooter(_ usage: SessionUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("Session usage")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: FleetTheme.spacingXl) {
                stat("CALLS", "\(usage.calls)")
                stat("IN", Self.compact(usage.input))
                stat("OUT", Self.compact(usage.output))
                stat("TOTAL", Self.compact(usage.total))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("context.breakdown.usage")
    }

    private func stat(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(FleetTheme.microLabelFont)
                .foregroundStyle(theme.textMuted)
            Text(value)
                .font(FleetTheme.monoFont)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
        }
    }

    private func tint(for percent: Int) -> Color {
        switch ContextMeterLevel.level(forPercent: percent) {
        case .alert: return FleetTheme.statusDestructive
        case .warn: return FleetTheme.statusNeedsIntervention
        case .normal: return theme.highlight
        }
    }

    /// 45_000 → "45.0k", 1_200_000 → "1.2M" (compact meter figures).
    public static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fk", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}
