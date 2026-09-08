import SwiftUI
import FleetCore

struct GatewayResourceView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    let screen: FleetScreen
    let onSelection: (ProfileSlug) -> Void
    @State private var selected: ProfileSlug?
    @State private var initialized = false

    init(environment: AppEnvironment, gatewayID: GatewayID, screen: FleetScreen, profile: ProfileSlug?, onSelection: @escaping (ProfileSlug) -> Void) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.screen = screen
        self.onSelection = onSelection
        _selected = State(initialValue: profile)
    }

    private var profiles: [FleetBot] {
        if case .loaded = environment.rosterSnapshot?.outcome(for: gatewayID) {
            return environment.bots(on: gatewayID).filter { $0.route.isRoutingSafe }
        }
        return (environment.cachedBotsByGateway[gatewayID] ?? []).filter { $0.route.isRoutingSafe }
    }
    private var storageKey: String { "fleet.explicit-profile.v1.\(gatewayID.rawValue)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(environment.gateway(for: gatewayID)?.displayName ?? gatewayID.rawValue)
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(profiles) { bot in
                        Button("\(bot.displayName) · \(bot.route.profileSlug.rawValue)") { choose(bot.route.profileSlug) }
                            .accessibilityIdentifier("fleet.scope.\(bot.route.id)")
                    }
                } label: {
                    Text(selected.map { "Profile: \($0.rawValue)" } ?? "Choose profile")
                }.accessibilityIdentifier("fleet.scope.selected")
            }.padding(.horizontal).padding(.vertical, 8)
            Divider()
            if let selected, profiles.contains(where: { $0.route.profileSlug == selected }) {
                content(selected).id(Route(gatewayID: gatewayID, profileSlug: selected))
            } else if selected != nil {
                ContentUnavailableView("Profile unavailable", systemImage: "person.crop.circle.badge.questionmark", description: Text("The selected profile is no longer available. Choose another profile explicitly to continue."))
            } else {
                List(profiles) { bot in
                    Button { choose(bot.route.profileSlug) } label: {
                        VStack(alignment: .leading) {
                            Text(bot.displayName)
                            Text(bot.route.id).font(.footnote).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("fleet.scope.\(bot.route.id)")
                }.overlay {
                    if profiles.isEmpty { ContentUnavailableView("Profiles unavailable", systemImage: "person.crop.circle", description: Text("Refresh this gateway's Bots to discover valid profiles.")) }
                }.navigationTitle("Choose profile")
            }
        }
        .task(id: profiles.map(\.route)) {
            guard !initialized, selected == nil, !profiles.isEmpty else { return }
            initialized = true
            if let saved = UserDefaults.standard.string(forKey: storageKey),
               profiles.contains(where: { $0.route.profileSlug.rawValue == saved }) {
                selected = ProfileSlug(rawValue: saved)
            } else if profiles.count == 1 {
                selected = profiles[0].route.profileSlug // Only one valid candidate, visibly labeled above.
            }
            if let selected { onSelection(selected) }
        }
    }
    private func choose(_ profile: ProfileSlug) {
        selected = profile
        UserDefaults.standard.set(profile.rawValue, forKey: storageKey)
        onSelection(profile)
    }
    @ViewBuilder private func content(_ profile: ProfileSlug) -> some View {
        switch screen {
        case .cron: CronView(environment: environment, gatewayID: gatewayID, profile: profile)
        case .skills: SkillsView(environment: environment, gatewayID: gatewayID, profile: profile)
        case .memoryGraph: MemoryGraphView(environment: environment, gatewayID: gatewayID, profile: profile)
        case .projects(_, _, let path): ProjectsView(environment: environment, gatewayID: gatewayID, profile: profile, focusPath: path)
        default: EmptyView()
        }
    }
}
