import SwiftUI
import FleetCore

/// Refinement Phase 2 — the in-flight turn's presence, as the agent itself.
///
/// One quiet capsule in the assistant's position: the Bot's face wearing a
/// breathing executing ring, then "Thinking" (a soft shimmer sweeps it) or
/// "Working", then the elapsed clock. GitHub #107 semantics are unchanged:
/// one indicator per turn, the clock appears for thinking only from 3s, and
/// the accessibility label and identifier are exactly the previous ones.
/// Reduce Motion: no ring breathing, no shimmer.
///
/// A nominal view so the transcript body stays shallow (#215).
struct ConversationPresenceIndicator: View {
    @Environment(\.fleetTheme) private var theme
    let presence: ConversationPresenceState
    let startedAt: Date?
    let bot: FleetBot?
    let management: BotManagementController

    var body: some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { timeline in
            let elapsed = Int(timeline.date.timeIntervalSince(startedAt ?? timeline.date))
            let thinking = presence == .thinking
            HStack(spacing: FleetTheme.spacingSm) {
                ConversationPresenceFace(bot: bot, management: management)
                if thinking {
                    ConversationShimmerText(text: "Thinking")
                } else {
                    Text("Working")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
                if !thinking || ConversationPresence.showsElapsed(elapsed) {
                    Text(ConversationView.workingDuration(elapsed))
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, FleetTheme.spacingMd)
            .padding(.vertical, 4)
            .background(theme.surfaceElevated, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenLabel(thinking: thinking, elapsed: elapsed))
            .accessibilityIdentifier("fleet.conversation.working")
        }
    }

    /// The previous spoken strings, verbatim (UI tests and VoiceOver users
    /// rely on "Thinking" / "Working for …").
    static func spokenLabel(thinking: Bool, elapsed: Int) -> String {
        if thinking {
            return ConversationPresence.showsElapsed(elapsed)
                ? "Thinking, \(ConversationView.workingSpoken(elapsed))"
                : "Thinking"
        }
        return "Working for \(ConversationView.workingSpoken(elapsed))"
    }
}

/// The Bot's face with the executing ring breathing around it.
private struct ConversationPresenceFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 24
    @State private var breathing = false
    let bot: FleetBot?
    let management: BotManagementController

    var body: some View {
        Group {
            if let bot {
                BotAvatar(bot: bot, management: management)
                    .scaleEffect(side / BotAvatar.side)
                    .frame(width: side, height: side)
                    .clipShape(Circle())
            } else {
                Image(systemName: "sparkle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FleetTheme.statusExecuting)
                    .frame(width: side, height: side)
            }
        }
        .overlay(
            Circle()
                .strokeBorder(FleetTheme.statusExecuting, lineWidth: 1.5)
                .scaleEffect(breathing ? 1.18 : 1)
                .opacity(breathing ? 0.25 : 0.9))
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// "Thinking" with a soft highlight sweeping across it. Static under Reduce
/// Motion. The sweep uses the theme's own text inks, so it reads in both
/// appearances and every palette.
private struct ConversationShimmerText: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, theme.textPrimary, .clear],
                        startPoint: UnitPoint(x: sweep - 0.3, y: 0.5),
                        endPoint: UnitPoint(x: sweep + 0.3, y: 0.5))
                    .mask(Text(text).font(.footnote.weight(.medium)))
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    sweep = 2
                }
            }
    }
}
