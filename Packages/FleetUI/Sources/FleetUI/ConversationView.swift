import SwiftUI
import FleetCore

/// Conversation canvas (U1 navigation placeholder — U3 implements the real
/// streaming/replay/reconnect canvas).
///
/// U1 scope guard: this destination exists so the Gateways → Bots → Sessions →
/// Conversation flow is walkable in the simulator, but the canvas itself is a
/// placeholder. NO chat UI, NO streaming, NO replay UX — that's U3.
public struct ConversationView: View {
    private let route: Route
    private let sessionID: String

    public init(route: Route, sessionID: String) {
        self.route = route
        self.sessionID = sessionID
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text("Conversation")
            } icon: {
                Image(systemName: "text.bubble")
                    .foregroundStyle(FleetTheme.accent)
            }
        } description: {
            Text("The conversation canvas arrives in a later milestone (U3).")
        }
        .navigationTitle(route.profileSlug.rawValue)
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.conversation")
    }
}
