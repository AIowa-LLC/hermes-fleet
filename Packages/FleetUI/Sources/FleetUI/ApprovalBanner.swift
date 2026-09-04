import SwiftUI
import FleetCore

/// R9-T1/T2 — the mid-session approval banner: a dangerous command is
/// blocked awaiting Tony's decision. DANGER surface (statusDegraded), mono
/// command preview, DENY friction-free (one tap), APPROVE biometric-gated
/// with a scope menu (once / session / always — only the choices the gateway
/// offered). Nous Direction A tokens; gold stays off (danger ≠ wordmark).
public struct ApprovalBanner: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Bindable var model: ApprovalViewModel
    /// Deny tap (the friction-free path) — owned by the parent so the
    /// banner itself stays presentational.
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
                    .foregroundStyle(FleetTheme.statusDegraded)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(FleetTheme.statusDegraded)
            }
            .accessibilityIdentifier("approval.banner.title")

            // Command preview — mono (telemetry identity), client-redacted.
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
                        .strokeBorder(FleetTheme.statusDegraded.opacity(0.4), lineWidth: 1)
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
                // DENY — friction-free by design (one tap, no biometrics,
                // no confirmation). The safe answer is never the hard one.
                Button(role: .destructive) {
                    onDeny()
                } label: {
                    Text("Deny")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("approval.deny")

                // APPROVE — biometric-gated. Scope menu offers only the
                // choices the gateway sent (default once/deny).
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
                .strokeBorder(FleetTheme.statusDegraded.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.banner")
        .accessibilityLabel("Approval required. Command: \(request.command)")
    }

    /// Approve with scope: tap = Approve once (the common case); the menu
    /// offers session/always only when the gateway offered them.
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
            .foregroundStyle(FleetTheme.statusDegraded)
            .accessibilityIdentifier("approval.banner.hint")
    }
}
