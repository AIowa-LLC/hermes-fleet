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
    @State private var showingReview = false

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
        if let request = model.pending {
            scrollingIfNeeded(banner(for: request))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        } else {
            EmptyView()
        }
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
            }
            .accessibilityIdentifier("approval.banner.title")

            // P0.2a: origin first (also first for VoiceOver), then the
            // client-redacted command preview with an explicit elision marker.
            ApprovalOriginHeader(origin: origin)

            ApprovalCommandPreviewView(command: request.command) {
                showingReview = true
            }

            if let detail = request.detail, !detail.isEmpty {
                ApprovalUntrustedDetail(detail: detail)
            }

            switch model.state {
            case .biometricFailed:
                hint("Face ID did not match. The command stays blocked — deny or try again.")
            case .biometricUnavailable:
                hint("Face ID unavailable. The command stays blocked until it can be verified.")
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
        .sheet(isPresented: $showingReview) {
            ApprovalReviewSheet(
                origin: origin,
                command: request.command,
                detail: request.detail,
                isReviewed: model.pendingIsReviewed
            ) {
                model.markReviewed(request)
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
            Task { await model.approve(scope: choice) }
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
            .accessibilityIdentifier("approval.approve")
        }
    }

    private func approveLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "faceid")
                .font(.caption.weight(.semibold))
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

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(FleetTheme.statusNeedsIntervention)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("approval.banner.hint")
    }
}
