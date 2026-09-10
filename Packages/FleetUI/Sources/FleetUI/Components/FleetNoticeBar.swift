import SwiftUI

/// FOS-6 (SPEC §18) — a bounded inline NOTICE: informational note, empty
/// collection hint, or non-interactive error text. One line of icon + text
/// (plus an optional action), NOT a card — a notice earns a border only
/// when it is a semantic recovery group (keep those on `FleetCard`).
///
/// The optional action keeps its own accessibilityIdentifier — the bar
/// never sets a container id and never `.combine`s when an action is
/// present (repo lesson: a container identifier/combine overrides child
/// ids). Without an action the bar is one combined VoiceOver stop.
public struct FleetNoticeBar: View {
    @Environment(\.fleetTheme) private var theme
    public enum Tone {
        case info
        case warning
        case error
    }

    private let text: String
    private let systemImage: String
    private let tone: Tone
    private let id: String
    private let actionTitle: String?
    private let actionID: String?
    private let action: (() -> Void)?

    /// Informational notice / empty-state hint.
    public init(
        _ text: String,
        systemImage: String = "info.circle",
        tone: Tone = .info,
        id: String
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.id = id
        self.actionTitle = nil
        self.actionID = nil
        self.action = nil
    }

    /// Notice with a bounded action (e.g. Retry).
    public init(
        _ text: String,
        systemImage: String = "info.circle",
        tone: Tone = .info,
        id: String,
        actionTitle: String,
        actionID: String? = nil,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.id = id
        self.actionTitle = actionTitle
        self.actionID = actionID
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FleetTheme.spacingMd) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(text)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(tone == .info ? theme.textSecondary
                    : (tone == .warning ? FleetTheme.statusNeedsIntervention : FleetTheme.statusDestructive))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(theme.highlight)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(actionID ?? "\(id).action")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: action == nil ? .combine : .contain)
        .accessibilityIdentifier(id)
    }

    private var symbolColor: Color {
        switch tone {
        case .info: theme.textSecondary
        case .warning: FleetTheme.statusNeedsIntervention
        case .error: FleetTheme.statusDestructive
        }
    }
}

#Preview("FleetNoticeBar") {
    VStack(spacing: FleetTheme.spacingLg) {
        FleetNoticeBar(
            "No cron jobs on this profile. Tap + to schedule one.",
            systemImage: "clock.badge.checkmark",
            id: "preview.cron.empty"
        )
        FleetNoticeBar(
            "Could not load schedules.",
            systemImage: "exclamationmark.triangle.fill",
            tone: .error,
            id: "preview.cron.error",
            actionTitle: "Retry",
            action: {}
        )
    }
    .padding()
    .background(FleetTheme.background)
}
