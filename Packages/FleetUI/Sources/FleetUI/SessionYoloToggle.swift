import SwiftUI
import FleetCore

/// R9-T3 — per-session YOLO toggle for the conversation toolbar.
///
/// SESSION-SCOPED ONLY (server.py:14967 `config.set yolo scope=session`):
/// flips this session's bypass flag, never the global `approvals.mode`,
/// never persisted, never survives restart — honest per-session copy.
/// Enabling shows a danger confirmation (deliberate friction); disabling is
/// immediate (restoring safety needs no friction). No biometric gate rides
/// the confirm action (spec requires the confirmation alert only); the
/// FaceID gate applies to approval-banner APPROVE, not to YOLO enable.
public struct SessionYoloToggle: View {
    @Bindable var model: ApprovalViewModel

    public init(model: ApprovalViewModel) {
        self.model = model
    }

    public var body: some View {
        Button {
            if model.isYoloEnabled {
                Task { await model.disableYolo() }
            } else {
                model.requestYoloEnable()
            }
        } label: {
            Image(systemName: model.isYoloEnabled ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.isYoloEnabled ? FleetTheme.statusNeedsIntervention : FleetTheme.textSecondary)
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel(model.isYoloEnabled ? "YOLO on" : "YOLO off")
        .accessibilityHint("Toggle approval bypass for this session only")
        .accessibilityIdentifier("approval.yolo.toggle")
        .confirmationDialog(
            "Enable YOLO for this session?",
            isPresented: yoloBinding,
            titleVisibility: .visible
        ) {
            Button("Enable — skip approvals this session", role: .destructive) {
                Task { await model.confirmYoloEnable() }
            }
            Button("Cancel", role: .cancel) {
                model.cancelYoloConfirmation()
            }
        } message: {
            Text("Dangerous commands will run on this session WITHOUT asking. "
                + "This session only — it never changes your saved approval settings "
                + "and resets when the session ends.")
        }
    }

    /// Two-way binding: entering `.confirmYolo` presents the dialog;
    /// dismissing any other way cancels.
    private var yoloBinding: Binding<Bool> {
        Binding(
            get: { model.state == .confirmYolo },
            set: { shown in
                if !shown { model.cancelYoloConfirmation() }
            }
        )
    }
}
