import SwiftUI
import FleetCore

/// Header-visible reasoning level, placed beside the model chip in the
/// conversation toolbelt, so the session's thinking level reads next to the
/// model it applies to. Tapping it opens a picker of the gateway-supported
/// levels; each pick goes through the SAME `ReasoningViewModel.apply(_:)` path
/// the slider uses (one write path, session-scoped `config.set`).
public enum ReasoningHeaderFormat {
    /// Placeholder shown while the level is unknown (not yet read, or the
    /// last read failed). Never a guessed level.
    public static let placeholder = "—"

    /// Label for the header chip. `nil` when the session has no reasoning
    /// seam (the knob is unsupported: the chip is hidden entirely).
    @MainActor
    public static func label(for model: ReasoningViewModel?) -> String? {
        guard let model else { return nil }
        return text(level: model.level, displayWord: model.displayWord)
    }

    /// `"Reasoning: Medium"` for a known level, the raw wire word for a
    /// readback Fleet does not map, and `"Reasoning: —"` when unknown.
    public static func text(level: FleetReasoningLevel?, displayWord: String) -> String {
        let trimmed = displayWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = level?.label ?? trimmed
        return "Reasoning: " + (word.isEmpty ? placeholder : word)
    }
}

/// Header chip + level picker. Hidden by the caller when the session has no
/// reasoning seam. `onShowError` opens the slider overlay when a pick fails,
/// so the failure surfaces exactly where the slider shows its errors.
public struct ReasoningHeaderChip: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ReasoningViewModel
    let onShowError: () -> Void

    public init(model: ReasoningViewModel, onShowError: @escaping () -> Void) {
        self.model = model
        self.onShowError = onShowError
    }

    public var body: some View {
        Menu {
            ForEach(FleetReasoningLevel.allCases, id: \.self) { level in
                Button {
                    Task { await Self.select(level, on: model, onFailure: onShowError) }
                } label: {
                    if level == model.level {
                        Label(level.label, systemImage: "checkmark")
                    } else {
                        Text(level.label)
                    }
                }
                .accessibilityIdentifier("fleet.conversation.reasoning.header.option.\(level.rawValue)")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Text(ReasoningHeaderFormat.text(level: model.level, displayWord: model.displayWord))
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(model.userAdjusted ? theme.highlight : theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.background, in: Capsule())
            // Identifier and AX payload live on the label content (a SwiftUI
            // Menu does not reliably expose its own identifier).
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reasoning level")
            .accessibilityValue(model.displayWord)
            .accessibilityHint("Choose how much this session reasons")
            .accessibilityIdentifier("fleet.conversation.reasoning.header")
        }
    }

    /// The single pick path: the same `apply(_:)` the slider drives. Opens
    /// the overlay when the apply failed so the error is never silent.
    @MainActor
    public static func select(
        _ level: FleetReasoningLevel,
        on model: ReasoningViewModel,
        onFailure: () -> Void
    ) async {
        await model.apply(level)
        if model.errorMessage != nil {
            onFailure()
        }
    }
}
