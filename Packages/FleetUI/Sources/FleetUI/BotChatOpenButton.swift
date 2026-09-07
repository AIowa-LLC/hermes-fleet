import SwiftUI
import FleetCore

/// Canonical "Bot Chat" open button (True Bots Mode).
///
/// Tap → `AppEnvironment.resolveCanonicalChatTarget` (fail-closed exact-title
/// contract) → navigate to `FleetScreen.conversation(route, sessionID:)` with
/// the canonical registry id. On unconfirmed lookup the button shows a
/// retryable error and issues NO navigation and NO session creation — a
/// transient registry failure can never fork a second "Bot Chat".
public struct BotChatOpenButton: View {
    private let environment: AppEnvironment
    private let bot: FleetBot

    @State private var isResolving = false
    @State private var failureMessage: String?

    public init(environment: AppEnvironment, bot: FleetBot) {
        self.environment = environment
        self.bot = bot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Button {
                openCanonical()
            } label: {
                HStack(spacing: FleetTheme.spacingSm) {
                    if isResolving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.caption)
                    }
                    Text("Bot Chat")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                .padding(FleetTheme.spacingMd)
                .frame(maxWidth: .infinity)
                .background(FleetTheme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusRow, style: .continuous))
            }
            .buttonStyle(FleetPressableStyle())
            .disabled(isResolving)
            .accessibilityIdentifier("fleet.bot-chat.open")

            if let failureMessage {
                Text(failureMessage)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(3)
                    .accessibilityIdentifier("fleet.bot-chat.error")
            }
        }
    }

    private func openCanonical() {
        guard !isResolving else { return }
        isResolving = true
        failureMessage = nil
        Task { @MainActor in
            defer { isResolving = false }
            switch await environment.resolveCanonicalChatTarget(for: bot) {
            case .success(let sessionID):
                environment.openBotChat(route: bot.route, sessionID: sessionID)
            case .failure(let unavailable):
                failureMessage = unavailable.message
            }
        }
    }
}
