import SwiftUI
import FleetCore

/// Settings rows for local approval notifications (B3). Off until the user
/// turns them on; enabling asks iOS for permission from this explicit action.
/// The details row is disabled while App Lock is on.
struct InboxNotificationsSettingsSection: View {
    let coordinator: InboxNotificationCoordinator
    @Environment(\.fleetTheme) private var theme
    @State private var notice: String?
    @State private var toggleRefresh = 0

    var body: some View {
        let settings = coordinator.settings
        Section {
            Toggle(isOn: Binding(
                get: { _ = toggleRefresh; return settings.isEnabled },
                set: { newValue in Task { await apply(newValue) } }
            )) {
                Label("Approval notifications", systemImage: "bell.badge")
                    .foregroundStyle(theme.textPrimary)
            }
            .accessibilityIdentifier("fleet.settings.inbox-notifications.toggle")

            Toggle(isOn: Binding(
                get: { settings.showsRequestDetails },
                set: { settings.setShowsRequestDetails($0) }
            )) {
                Label("Show request details", systemImage: "text.alignleft")
                    .foregroundStyle(theme.textPrimary)
            }
            .disabled(!settings.isEnabled || coordinator.isAppLockEnabled)
            .accessibilityIdentifier("fleet.settings.inbox-notifications.details")

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.settings.inbox-notifications.notice")
            }
        } header: {
            Text("Notifications")
                .foregroundStyle(theme.textSecondary)
        } footer: {
            Text(footerText(settings: settings))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func footerText(settings: InboxNotificationSettingsStore) -> String {
        var text = "Get a notification when an agent needs your approval or an answer. "
            + "Deny works from the notification; approve and answer in the app. "
            + "Notifications are off until you turn them on."
        if coordinator.isAppLockEnabled {
            text += " Request details stay hidden while App Lock is on."
        } else {
            text += " Details include a shortened command. Passwords, secrets and answers are never shown."
        }
        return text
    }

    private func apply(_ enabled: Bool) async {
        notice = nil
        let accepted = await coordinator.setEnabled(enabled)
        if enabled && !accepted {
            notice = "Notifications are off for Hermes Fleet in iOS Settings. Turn them on there first."
        }
        toggleRefresh += 1
    }
}
