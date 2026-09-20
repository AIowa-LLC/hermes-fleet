import SwiftUI
import Observation
import FleetCore

/// Dogfood r8 — session reasoning level (thinking level) view model.
///
/// Read on session open (`config.get reasoning`), applied on slider release
/// (`config.set reasoning scope=session`). SESSION-SCOPED ONLY — never the
/// global `agent.reasoning_effort`. Failures are surfaced, never silenced:
/// an apply error reverts the optimistic level and shows an inline message
/// in the overlay (the house never-silent rule).
@MainActor
@Observable
public final class ReasoningViewModel {

    // MARK: Observable state

    /// The session's current level (nil = unknown readback: the chip shows
    /// `displayWord` verbatim and the slider marks no stop).
    public private(set) var level: FleetReasoningLevel?
    /// Chip/overlay word: the mapped label, or the raw wire word when
    /// unknown (honest unknown, never a guess).
    public private(set) var displayWord: String
    /// True once the user has changed the level THIS session (chip ink
    /// signal, mirrors the model chip's sticky-pick coloring).
    public private(set) var userAdjusted = false
    public private(set) var isLoading = false
    public private(set) var isApplying = false
    /// Never-silent apply/load failure (rendered inside the overlay).
    public private(set) var errorMessage: String?

    // MARK: Injected seams

    private let reasoning: any ReasoningProviding
    private var boundSessionID: String?

    public init(reasoning: any ReasoningProviding, initial: FleetReasoningLevel? = nil) {
        self.reasoning = reasoning
        self.level = initial
        self.displayWord = initial?.label ?? "—"
    }

    /// Bind to the open runtime session and read the current level.
    /// Self-loading: the open path calls bind once (ApprovalViewModel shape
    /// plus the initial read the banner gets from session.info).
    public func bind(sessionID: String?) {
        boundSessionID = sessionID
        guard let sessionID else { return }
        Task { await load(sessionID: sessionID) }
    }

    /// `config.get reasoning` readback. A failed read leaves the previous
    /// state and surfaces the error — never a silent default.
    public func load(sessionID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let state = try await reasoning.reasoning(sessionID: sessionID)
            level = state.level
            displayWord = state.level?.label ?? (state.rawValue.isEmpty ? "—" : state.rawValue)
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error, action: "reading")
        }
    }

    /// Apply a level (slider release / AX adjust). Optimistic set, reverted
    /// fail-closed when the gateway disagrees.
    public func apply(_ newLevel: FleetReasoningLevel) async {
        guard !isApplying, newLevel != level else { return }
        guard let sessionID = boundSessionID else {
            errorMessage = "No session to configure."
            return
        }
        let previous = level
        let previousWord = displayWord
        isApplying = true
        // Optimistic paint (the drag already showed the stop); reverted on
        // any failure so the chip never lies about the session's state.
        level = newLevel
        displayWord = newLevel.label
        defer { isApplying = false }
        do {
            let reported = try await reasoning.setReasoning(newLevel, sessionID: sessionID)
            level = reported
            displayWord = reported.label
            userAdjusted = true
            errorMessage = nil
        } catch {
            level = previous
            displayWord = previousWord
            errorMessage = Self.message(for: error, action: "setting")
        }
    }

    /// VoiceOver adjustable step (wraps at the ends, applies each step).
    public func adjust(_ direction: Int) async {
        let stops = FleetReasoningLevel.allCases
        let current = level ?? .defaultLevel
        guard let idx = stops.firstIndex(of: current) else { return }
        let next = stops[(idx + direction + stops.count) % stops.count]
        await apply(next)
    }

    private static func message(for error: Error, action: String) -> String {
        if let conversationError = error as? ConversationError,
           let text = conversationError.errorDescription, !text.isEmpty {
            return "Couldn't \(action) the thinking level: \(text)."
        }
        return "Couldn't \(action) the thinking level."
    }
}

/// r8.1 — the composer's thinking-level button (ChatGPT placement: right
/// cluster, first position — between the field and the mic). Icon-only,
/// level-encoding gauge (Tony's pick B): the gauge needle itself carries
/// the session's current level. Symbols verified on this host (2026-09-20):
/// dial.min, gauge.low, gauge.medium, gauge.high all exist.
///
/// Ink follows the r6 pill rule: bare glyph, themed highlight when the
/// user adjusted the level this session (the accent-active signal, like
/// ChatGPT's purple Search toggle), secondary at default. The AX contract
/// is unchanged from the r8 chip (id + value carry the word) — zero test
/// edits by design.
public struct ReasoningChip: View {
    @Bindable var model: ReasoningViewModel
    let onOpen: () -> Void

    public init(model: ReasoningViewModel, onOpen: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    /// Level → arc fraction of the dial (the strip length IS the level).
    /// Anchored so the resting default (medium) reads ~half — the ChatGPT
    /// reference's visual weight — with high nearly full and none empty.
    private var fraction: CGFloat {
        switch model.level {
        case .off: return 0
        case .minimal: return 0.2
        case .low: return 0.35
        case .medium: return 0.5
        case .high: return 0.65
        case .xhigh: return 0.78
        case .max: return 0.9
        case .ultra: return 1.0
        case nil: return 0.5
        }
    }

    public var body: some View {
        Button(action: onOpen) {
            // r8.3 (Tony's dogfood): the icon is a DRAWN DIAL, not an SF
            // Symbol — ChatGPT's is a thin neutral ring + an accent ARC
            // STRIP whose fill length encodes the reasoning level (≈half
            // the ring at medium, sweeping counterclockwise from 12
            // o'clock) + a small hub dot. The accent marks the control;
            // the STRIP is the level readout, and it re-renders live as
            // the slider applies a new stop.
            ReasoningGaugeDial(
                fraction: fraction,
                active: model.level != .off
            )
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel("Thinking level")
        .accessibilityValue(model.displayWord)
        .accessibilityHint("Adjust how much this session reasons")
        .accessibilityIdentifier("fleet.conversation.reasoning.chip")
    }
}

/// The ChatGPT-style reasoning dial: neutral track ring, theme-highlight
/// arc strip (level fraction, rounded caps, counterclockwise from 12),
/// center hub dot. All colors from `.fleetTheme`.
struct ReasoningGaugeDial: View {
    @Environment(\.fleetTheme) private var theme
    let fraction: CGFloat
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.textSecondary.opacity(0.55), lineWidth: 2)
            Circle()
                .trim(from: 1 - fraction, to: 1)
                .stroke(theme.highlight,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(active ? theme.highlight : theme.textSecondary.opacity(0.55))
                .frame(width: 4.5, height: 4.5)
        }
        .padding(4)
        .accessibilityHidden(true)
    }
}

/// r8 overlay — Gemini-style thinking slider presented above the composer:
/// scrim + bottom panel, drag-anywhere capsule with stop snap, apply on
/// release. NOT a sheet (no presentation animation can drop taps). Every
/// color is a `.fleetTheme` token — the fill is the user's highlight, never
/// a hardcoded brand color.
public struct ReasoningSliderOverlay: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ReasoningViewModel
    let onDismiss: () -> Void

    public init(model: ReasoningViewModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    @State private var dragFraction: Double?

    private var stops: [FleetReasoningLevel] { FleetReasoningLevel.allCases }

    /// The stop currently shown (mid-drag follows the finger; at rest the
    /// session's level; unknown readback → medium anchor, no snap mark).
    private var displayLevel: FleetReasoningLevel {
        model.level ?? .defaultLevel
    }

    private var fraction: Double {
        dragFraction ?? Double(displayLevel.stopIndex) / Double(stops.count - 1)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim: tap-outside dismisses. A Color (not a Rectangle shape)
            // with the button trait is a real AX element — the drawer-scrim
            // pattern (fleet.drawer.scrim).
            theme.background.opacity(0.6)
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("Close thinking level")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("fleet.conversation.reasoning.scrim")
            panel
                .padding(.horizontal, FleetTheme.spacingLg)
                .padding(.bottom, FleetTheme.spacingLg)
        }
    }

    private var panel: some View {
        VStack(spacing: FleetTheme.spacingSm) {
            Text("Thinking level")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
            Text(displayLevel.label)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.conversation.reasoning.value")
            capsule
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("fleet.conversation.reasoning.error")
            }
        }
        .padding(FleetTheme.spacingMd)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow, style: .continuous)
                .fill(theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    /// Drag-anywhere capsule: minimumDistance 0 makes a tap a zero-move
    /// drag, so tap-to-jump and drag share ONE seam (snap on end + apply).
    private var capsule: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let handleSide: CGFloat = 32
            let travel = max(0, width - handleSide)
            let handleX = fraction * travel
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.surfaceElevated)
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                // Fill from the leading edge to the handle — the active
                // highlight, per-theme (never a hardcoded tint).
                Capsule()
                    .fill(theme.highlight)
                    .frame(width: handleX + handleSide / 2)
                // Stop ticks: ≤ current stop in ink-on-highlight, rest border.
                ForEach(0..<stops.count, id: \.self) { i in
                    let stopX = Double(i) / Double(stops.count - 1) * travel + handleSide / 2
                    Circle()
                        .fill(i <= displayLevel.stopIndex ? AnyShapeStyle(theme.onHighlight) : AnyShapeStyle(theme.border))
                        .frame(width: 6, height: 6)
                        .position(x: stopX, y: proxy.size.height / 2)
                }
                // Handle: max-contrast ink circle on the highlight fill —
                // legible for every curated accent (ADR-0009 seam).
                Circle()
                    .fill(theme.onHighlight)
                    .frame(width: handleSide, height: handleSide)
                    .shadow(color: theme.highlight.opacity(0.35), radius: 10, x: handleX / 4, y: 0)
                    .position(x: handleX + handleSide / 2, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = min(max(Double(value.location.x - handleSide / 2) / Double(travel), 0), 1)
                    }
                    .onEnded { _ in
                        if let dragFraction {
                            let index = Int((dragFraction * Double(stops.count - 1)).rounded())
                            let stop = stops[min(index, stops.count - 1)]
                            Task { await model.apply(stop) }
                        }
                        self.dragFraction = nil
                    }
            )
        }
        .frame(height: 56)
        // One adjustable element: VoiceOver reads the word, ± steps apply
        // (RT4 hygiene — the readout word is NOT duplicated into AX).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking level")
        .accessibilityValue(model.displayWord)
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            Task { await model.adjust(step) }
        }
        .accessibilityIdentifier("fleet.conversation.reasoning.slider")
        .sensoryFeedback(.selection, trigger: model.level)
    }
}
