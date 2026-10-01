import SwiftUI
import FleetCore

/// Honest copy shared by the Settings row and the explain-first card. The
/// notifications are interim and local: they only work while Fleet was
/// recently open.
enum LocalNotificationCopy {
    static let settingsFooter =
        "Only while Fleet was recently open; use push notifications for reliable delivery. "
        + "Notifications never include commands, secrets, or message text."
    static let deniedHint =
        "Notifications are turned off for Hermes Fleet in the system Settings app."
    static let unavailableHint = "Notifications are not available in this build."
    static let offerTitle = "Get a heads-up when a bot needs you?"
    static let offerBody =
        "Fleet can post a local notification when an approval or question arrives while this "
        + "screen is not showing. It never includes the command or message text, and it only "
        + "works while Fleet was recently open. It is not push."
}

/// The Settings "Local notifications" section. Turning it on is the only place
/// (besides the explain-first card) that asks the system for permission.
struct LocalNotificationsSettingsSection: View {
    let coordinator: LocalNotificationCoordinator
    @Environment(\.fleetTheme) private var theme

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { coordinator.isDeliveryActive },
                set: { newValue in Task { await coordinator.setEnabled(newValue) } }
            )) {
                Label("Local notifications", systemImage: "bell.badge")
                    .foregroundStyle(theme.textPrimary)
            }
            .disabled(!coordinator.isAvailable)
            .accessibilityIdentifier("fleet.settings.local-notifications.toggle")
            .accessibilityHint(
                "Posts a notification when a bot needs approval or answers, only while Fleet was recently open.")

            if coordinator.authorization == .denied {
                Text(LocalNotificationCopy.deniedHint)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.settings.local-notifications.denied")
            }
        } header: {
            Text("Notifications")
                .foregroundStyle(theme.textSecondary)
        } footer: {
            Text(coordinator.isAvailable
                 ? LocalNotificationCopy.settingsFooter
                 : LocalNotificationCopy.unavailableHint)
                .foregroundStyle(theme.textSecondary)
                .accessibilityIdentifier("fleet.settings.local-notifications.footer")
        }
        .task { await coordinator.refreshAuthorization() }
    }
}

/// Explain-first card shown in a conversation at the first approval-worthy
/// moment, before anything asks the system for permission. Non-blocking: the
/// approval controls stay reachable above and below it.
struct LocalNotificationOfferCard: View {
    let coordinator: LocalNotificationCoordinator
    @Environment(\.fleetTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Label(LocalNotificationCopy.offerTitle, systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("notifications.offer.title")
            Text(LocalNotificationCopy.offerBody)
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FleetTheme.spacingSm) { buttons }
                VStack(spacing: FleetTheme.spacingSm) { buttons }
            }
        }
        .padding(FleetTheme.spacingMd)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications.offer.card")
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Not Now") { coordinator.declineOffer() }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("notifications.offer.decline")
            .accessibilityHint("Dismisses this. You can turn notifications on later in Settings.")
        Button("Turn On") { Task { await coordinator.acceptOffer() } }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .accessibilityIdentifier("notifications.offer.accept")
            .accessibilityHint("Asks iOS for permission to post notifications.")
    }
}
