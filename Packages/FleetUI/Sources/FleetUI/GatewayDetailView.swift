import SwiftUI
import FleetCore

/// Machine cockpit. Operational facts and resources share one explicit gateway.
struct GatewayDetailView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    private var gateway: FleetGateway? { environment.gateway(for: gatewayID) }
    private var bots: [FleetBot] { environment.bots(on: gatewayID).isEmpty ? environment.cachedBotsByGateway[gatewayID] ?? [] : environment.bots(on: gatewayID) }
    private var working: [FleetBot] { bots.filter { [.working, .thinking, .usingTool].contains($0.activity) && environment.botPresence(for: $0.route) == .reachable } }
    private var observed: Int { bots.filter { $0.activity != .unknown && environment.botPresence(for: $0.route) == .reachable }.count }

    var body: some View {
        if let gateway {
            List {
                Section {
                    Label(gateway.displayName, systemImage: "server.rack").font(.headline)
                    LabeledContent("Phone connection", value: GatewayConnectionCopy.label(environment.connectionStates[gatewayID] ?? .idle))
                    Text(gateway.endpoint.map(Redaction.redactedURL) ?? "Endpoint not configured")
                        .font(.footnote).foregroundStyle(.secondary)
                    switch environment.rosterSnapshot?.outcome(for: gatewayID) {
                    case .loaded(let count): LabeledContent("Known Bots", value: "\(count)")
                    default: LabeledContent("Known Bots", value: bots.isEmpty ? "Unknown" : "\(bots.count) · last known")
                    }
                    Text(observed == 0 ? "Activity unknown · no current execution observations" : "\(working.count) active · activity observed for \(observed) of \(bots.count) known Bots")
                        .font(.footnote).accessibilityIdentifier("fleet.gateway-detail.activity-coverage")
                    Text("Attention coverage is limited to observed Bots and Groups.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if case .failed(.authenticationRequired) = environment.connectionStates[gatewayID] {
                    Section("Needs You") {
                        NavigationLink("Sign in to this gateway", value: FleetScreen.gatewayConnection(gatewayID))
                    }
                }
                if !working.isEmpty {
                    Section("Working here") {
                        ForEach(working.prefix(3)) { bot in
                            NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                                LabeledContent(bot.displayName, value: bot.activity.rawValue)
                            }
                        }
                    }
                }
                Section("Resources") {
                    resource("Bots", "cpu", .bots(gatewayID), "bots")
                    resource("Groups", "person.3", .gatewayGroups(gatewayID), "groups")
                    resource("Projects", "folder", .projects(gatewayID), "projects")
                    resource("Kanban", "rectangle.split.3x1", .gatewayKanban(gatewayID), "kanban")
                    resource("Schedules", "calendar", .cron(gatewayID), "cron")
                    resource("Skills", "sparkles", .skills(gatewayID), "skills")
                    resource("Memory", "point.3.connected.trianglepath.dotted", .memoryGraph(gatewayID), "memory")
                }
                Section {
                    resource("Connection", "network", .gatewayConnection(gatewayID), "connection")
                } footer: {
                    Text("Connection controls affect this phone's connection. Bots continue on the gateway.")
                }
            }
            .navigationTitle(gateway.displayName).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("fleet.gateway-detail.\(gatewayID.rawValue)")
        }
    }

    private func resource(_ title: String, _ icon: String, _ screen: FleetScreen, _ key: String) -> some View {
        NavigationLink(value: screen) { Label(title, systemImage: icon) }
            .accessibilityIdentifier("fleet.gateway-detail.\(gatewayID.rawValue).\(key)")
    }
}

enum GatewayConnectionCopy {
    static func label(_ state: GatewayConnectionState) -> String {
        switch state {
        case .idle: "Not checked"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .failed(.authenticationRequired): "Sign in required"
        case .failed(.unsupported): "Unsupported endpoint"
        case .failed(.degraded): "Degraded"
        case .failed: "Unavailable from this phone"
        }
    }
}

struct GatewayGroupsView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    var body: some View {
        List {
            if environment.rooms(for: gatewayID).isEmpty {
                Text("No Groups observed on this gateway. Refresh Bots to check again.")
            }
            ForEach(environment.rooms(for: gatewayID), id: \.id) { room in
                NavigationLink(value: FleetScreen.room(room.id)) {
                    VStack(alignment: .leading) {
                        Text(room.name)
                        Text(room.id.provenance == .desktopLegacy ? "Managed by Hermes Desktop · read only" : "Hosted Group")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Groups").navigationBarTitleDisplayMode(.inline)
    }
}
