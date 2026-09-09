import SwiftUI
import FleetCore

/// Mid-session approval banner for commands that require an explicit user
/// decision. Denial is one tap; approval is biometric-gated and offers only
/// the scopes supplied by the gateway.
public struct ApprovalBanner: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Bindable var model: ApprovalViewModel
    /// Deny tap owned by the parent so the banner remains presentational.
    var onDeny: () -> Void

    public init(model: ApprovalViewModel, onDeny: @escaping () -> Void) {
        self.model = model
        self.onDeny = onDeny
    }

    public var body: some View {
        if let request = model.pending {
            banner(for: request)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            EmptyView()
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

            // Client-redacted command preview.
            Text(request.command)
                .font(FleetTheme.monoFont)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FleetTheme.spacingSm)
                .padding(.vertical, 6)
                .background(
                    FleetTheme.background,
                    in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                        .strokeBorder(FleetTheme.statusNeedsIntervention.opacity(0.4), lineWidth: 1)
                )
                .accessibilityIdentifier("approval.banner.command")

            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(2)
            }

            switch model.state {
            case .biometricFailed:
                hint("Face ID did not match. The command stays blocked — deny or try again.")
            case .biometricUnavailable:
                hint("Face ID unavailable. The command stays blocked until it can be verified.")
            case .respondFailed(let message):
                hint(message)
            case .pending, .idle, .confirmYolo:
                EmptyView()
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
        .padding(FleetTheme.spacingMd)
        .background(
            FleetTheme.surface,
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
        .accessibilityLabel("Approval required. Command: \(request.command)")
    }

    /// Tap approves once; the menu adds broader scopes only when offered by
    /// the gateway.
    @ViewBuilder
    private func approveMenu(for request: ApprovalRequest) -> some View {
        let offered = Set(request.choices)
        let approveAction: (ApprovalChoice) -> Void = { choice in
            Task { await model.approve(scope: choice) }
        }
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
            .accessibilityIdentifier("approval.approve")
        } else {
            Button {
                approveAction(.once)
            } label: {
                approveLabel("Approve")
            }
            .buttonStyle(.fleetPressable)
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
        .foregroundStyle(FleetTheme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            FleetTheme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .strokeBorder(FleetTheme.accent.opacity(0.4), lineWidth: 1)
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(FleetTheme.statusNeedsIntervention)
            .accessibilityIdentifier("approval.banner.hint")
    }
}
