import SwiftUI
import FleetCore

/// Mid-session approval banner for commands that require an explicit user
/// decision. Denial is one tap; approval is biometric-gated and offers only
/// the scopes supplied by the gateway.
public struct ApprovalBanner: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: ApprovalViewModel
    /// P0.2a: who is asking (gateway, bot, folder, session). Built by the
    /// parent from its own conversation context, never from the wire payload.
    var origin: ApprovalOrigin
    /// Deny tap owned by the parent so the banner remains presentational.
    var onDeny: () -> Void
    @State private var reviewingRequest: ApprovalRequest?
    /// Request id of a Deny tap still waiting for the gateway to clear it.
    @State private var denyAwaitingRequestID: String?
    /// Haptic triggers: bumped only once the gateway has accepted the decision.
    @State private var approveFeedback = 0
    @State private var denyFeedback = 0
    /// Refinement Phase 3: the brief "Approved" confirmation shown in the
    /// banner's place once the gateway accepts an approval.
    @State private var showsApprovedMoment = false

    public init(
        model: ApprovalViewModel,
        origin: ApprovalOrigin = .unknown,
        onDeny: @escaping () -> Void
    ) {
        self.model = model
        self.origin = origin
        self.onDeny = onDeny
    }

    public var body: some View {
        Group {
            if let request = model.pending {
                scrollingIfNeeded(banner(for: request))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            } else if showsApprovedMoment {
                ApprovalApprovedMoment(isPresented: $showsApprovedMoment)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            } else {
                EmptyView()
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3), value: showsApprovedMoment)
        // Observed here, not on the banner, so the clearing of `pending` (the
        // gateway accepting a Deny) is still seen after the banner disappears.
        .onChange(of: model.pending?.requestID) { _, current in
            guard let awaiting = denyAwaitingRequestID, current != awaiting else { return }
            denyAwaitingRequestID = nil
            denyFeedback += 1
        }
        .onChange(of: model.state) { _, state in
            if case .respondFailed = state { denyAwaitingRequestID = nil }
        }
        .fleetHaptic(.approve, trigger: approveFeedback)
        .fleetHaptic(.deny, trigger: denyFeedback)
    }

    /// At accessibility text sizes the card can outgrow the screen; keep it
    /// scrollable within a bounded height so the transcript and the Deny /
    /// Approve buttons stay reachable.
    @ViewBuilder
    private func scrollingIfNeeded(_ content: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView { content }
                .frame(maxHeight: 420)
                .scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }

    private func banner(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Label {
                Text("APPROVAL REQUIRED")
                    .font(FleetTheme.monoCaptionFont.weight(.semibold))
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("approval.banner.title")

            // P0.2a: origin first (also first for VoiceOver), then the
            // client-redacted command preview with an explicit elision marker.
            ApprovalOriginHeader(origin: origin)

            ApprovalCommandPreviewView(command: request.command) {
                reviewingRequest = request
            }

            if let detail = request.detail, !detail.isEmpty {
                ApprovalUntrustedDetail(detail: detail)
            }

            switch model.state {
            case .biometricFailed:
                presenceHint(.failed)
            case .authCancelled:
                presenceHint(.cancelled)
            case .passcodeNotSet:
                presenceHint(.passcodeNotSet)
            case .respondFailed(let message):
                hint(message)
            case .pending, .idle, .confirmYolo, .reviewRequired:
                EmptyView()
            }
            if !model.canApprove {
                hint("Approve is off until you review the full command. Deny is always available.")
            }

            HStack(spacing: FleetTheme.spacingMd) {
                // Denial stays friction-free: one tap, no biometric prompt or
                // confirmation step.
                Button(role: .destructive) {
                    denyAwaitingRequestID = request.requestID
                    onDeny()
                } label: {
                    Text("Deny")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("approval.deny")

                // Approval is biometric-gated and exposes only gateway-offered
                // scopes.
                approveMenu(for: request)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(FleetTheme.spacingMd)
        .background(
            theme.surface,
            in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                .strokeBorder(FleetTheme.statusNeedsIntervention.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.banner")
        .accessibilityLabel(accessibilitySummary(for: request))
        .sheet(item: $reviewingRequest) { snapshot in
            ApprovalReviewSheet(
                origin: origin,
                command: snapshot.command,
                detail: snapshot.detail,
                isReviewed: model.pendingIsReviewed
            ) {
                model.markReviewed(snapshot)
            }
        }
        .onChange(of: model.pending) { _, current in
            guard let snapshot = reviewingRequest else { return }
            if current?.requestID != snapshot.requestID || current?.sessionID != snapshot.sessionID
                || current?.command != snapshot.command {
                reviewingRequest = nil
            }
        }
    }

    /// Origin first, then the (possibly truncated) command, so VoiceOver
    /// says who is asking before what they are asking to run.
    private func accessibilitySummary(for request: ApprovalRequest) -> String {
        let preview = ApprovalCommandPreview(command: request.command)
        var summary = "Approval required. \(origin.accessibilityDescription) Command: \(preview.visibleText)"
        if let marker = preview.elisionMarker {
            summary += ". Command truncated, \(marker.replacingOccurrences(of: "… ", with: "")). "
            summary += model.pendingIsReviewed
                ? "Full command reviewed."
                : "Use Review full command before approving."
        }
        return summary
    }

    /// Tap approves once; the menu adds broader scopes only when offered by
    /// the gateway.
    @ViewBuilder
    private func approveMenu(for request: ApprovalRequest) -> some View {
        let offered = Set(request.choices)
        let approveAction: (ApprovalChoice) -> Void = { choice in
            let requestID = request.requestID
            Task {
                await model.approve(scope: choice)
                // The gateway accepted it only if the pending request moved on;
                // a failed or cancelled presence check leaves it in place.
                if model.pending?.requestID != requestID {
                    approveFeedback += 1
                    showsApprovedMoment = true
                }
            }
        }
        let allowed = model.canApprove
        if offered.contains("session") || offered.contains("always") {
            Menu {
                Button("Approve once") { approveAction(.once) }
                if offered.contains("session") {
                    Button("Approve for this session") { approveAction(.session) }
                }
                if offered.contains("always") {
                    Button("Approve always (persisted rule)") { approveAction(.always) }
                }
            } label: {
                approveLabel("Approve")
            }
            .disabled(!allowed)
            .opacity(allowed ? 1 : 0.45)
            .accessibilityHint("Requires Face ID or your device passcode")
            .accessibilityIdentifier("approval.approve")
        } else {
            Button {
                approveAction(.once)
            } label: {
                approveLabel("Approve")
            }
            .buttonStyle(.fleetPressable)
            .disabled(!allowed)
            .opacity(allowed ? 1 : 0.45)
            .accessibilityHint("Requires Face ID or your device passcode")
            .accessibilityIdentifier("approval.approve")
        }
    }

    private func approveLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "faceid")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(theme.highlight)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .strokeBorder(theme.highlight.opacity(0.4), lineWidth: 1)
        )
    }

    /// P0.2b: inline, announced feedback for a presence check that did not
    /// verify (worded for the action that was attempted).
    @ViewBuilder
    private func presenceHint(_ result: PresenceResult) -> some View {
        if let text = PresenceFeedback.message(for: result, action: model.lastPresenceAction) {
            hint(text)
                .onAppear { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(FleetTheme.statusNeedsIntervention)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("approval.banner.hint")
    }
}

/// Refinement Phase 3 approval success moment: a compact confirmation that
/// replaces the banner for a beat after the gateway accepts an approval, so
/// the decision visibly lands instead of the card just vanishing. The seal
/// bounces once; Reduce Motion keeps it still. Presentation only — it is
/// driven by the same gateway-accepted trigger as the approve haptic. It
/// owns its own dismissal: the banner's body is a `Group`, which copies
/// modifiers onto each child, so a timer there would restart on every swap.
struct ApprovalApprovedMoment: View {
    static let holdSeconds = 1.6
    @Binding var isPresented: Bool
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(FleetTheme.statusOnline)
                .symbolEffect(.bounce, value: landed)
                .accessibilityHidden(true)
            Text("Approved")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, FleetTheme.spacingMd)
        .padding(.vertical, FleetTheme.spacingSm)
        .background(theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(FleetTheme.statusOnline.opacity(0.5), lineWidth: 1))
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { landed = true } }
        .task {
            AccessibilityNotification.Announcement("Approved").post()
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            isPresented = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("approval.approved-moment")
    }
}
