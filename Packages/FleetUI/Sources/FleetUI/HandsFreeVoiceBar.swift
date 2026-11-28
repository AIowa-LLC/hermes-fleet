import SwiftUI

/// Hands-free voice mode bar, shown above the composer while the listen,
/// send, speak loop runs. The whole bar is one large tap target so it works
/// at a glance: while listening a tap means "done talking", while speaking a
/// tap cuts in and starts listening. End stops hands-free.
///
/// Its own struct (not a composer helper) so the composer body stays small
/// for Debug-build stack depth (#217).
struct HandsFreeVoiceBar: View {
    @Environment(\.fleetTheme) private var theme

    let phase: ConversationViewModel.HandsFreePhase
    let onTap: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Button(action: onTap) {
                HStack(spacing: FleetTheme.spacingSm) {
                    Image(systemName: glyph)
                        .font(.title3)
                        .foregroundStyle(phase == .listening ? theme.highlight : theme.textPrimary)
                        .symbolEffect(.variableColor.iterative, isActive: phase != .thinking)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(phase == .thinking)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
            .accessibilityIdentifier("fleet.conversation.handsFree.tap")

            Button("End", action: onEnd)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, FleetTheme.spacingMd)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.surfaceElevated))
                .accessibilityLabel("End hands-free voice")
                .accessibilityIdentifier("fleet.conversation.handsFree.end")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.handsFree.bar")
    }

    private var glyph: String {
        switch phase {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .off: return "waveform"
        }
    }

    private var title: String {
        switch phase {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .off: return "Hands-free off"
        }
    }

    private var hint: String {
        switch phase {
        case .listening: return "Tap when you're done talking"
        case .thinking: return "Waiting for the reply"
        case .speaking: return "Tap to cut in"
        case .off: return ""
        }
    }
}
