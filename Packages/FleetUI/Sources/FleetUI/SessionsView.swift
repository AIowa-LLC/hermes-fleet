import SwiftUI
import FleetCore

/// Sessions for a bot route (U1 navigation skeleton).
///
/// U1 scope: the Sessions destination exists to keep the Gateways → Bots →
/// Sessions → Conversation flow walkable. It renders the bot identity (route)
/// and a placeholder — the real `session.list` read path lands in U2. Tapping
/// the placeholder drills into the Conversation destination (U3 canvas).
public struct SessionsView: View {
    private let environment: AppEnvironment
    private let route: Route

    public init(environment: AppEnvironment, route: Route) {
        self.environment = environment
        self.route = route
    }

    public var body: some View {
        let bot = environment.bot(for: route)
        Group {
            if let bot {
                sessionSkeleton(bot)
            } else {
                unknownRoute
            }
        }
        .navigationTitle(bot?.displayName ?? route.profileSlug.rawValue)
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.sessions")
    }

    private func sessionSkeleton(_ bot: FleetBot) -> some View {
        List {
            Section {
                // U2 replaces this skeleton with the real `session.list` read
                // path (via the FleetCore `SessionHistoryProviding`/roster
                // seam). For U1, one row proves the drill-down to Conversation.
                NavigationLink(value: FleetScreen.conversation(route, sessionID: "session-placeholder")) {
                    HStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(FleetTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Conversation")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(FleetTheme.textPrimary)
                            Text(route.id)
                                .font(.caption)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .monospaced()
                        }
                    }
                }
                .accessibilityIdentifier("fleet.sessions.row.conversation")
            } header: {
                Text("Sessions")
            } footer: {
                Text("Session history lands in U2; conversation canvas in U3.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
        .accessibilityIdentifier("fleet.sessions.list")
    }

    private var unknownRoute: some View {
        ContentUnavailableView {
            Label {
                Text("Bot Unavailable")
            } icon: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(FleetTheme.accent)
            }
        } description: {
            Text("This bot is not in the current roster. Refresh the fleet.")
        }
        .accessibilityIdentifier("fleet.sessions.unknown")
    }
}
