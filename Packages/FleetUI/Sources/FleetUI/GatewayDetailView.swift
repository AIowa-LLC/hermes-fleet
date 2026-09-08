import SwiftUI
import FleetCore

/// FOS-2 (SPEC §8) — the machine cockpit. Identity, honest coverage, the
/// machine-owned Needs You item, current work, and dense resource rows —
/// all sharing one explicit gateway.
struct GatewayDetailView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    @State private var authGatewayID: GatewayID?
    @State private var operationError: String?

    private var gateway: FleetGateway? { environment.gateway(for: gatewayID) }
    private var connectionState: GatewayConnectionState { environment.connectionStates[gatewayID] ?? .idle }
    private var needsAuth: Bool {
        if case .failed(.authenticationRequired) = connectionState { return true }
        return false
    }

    /// Known Bots: live roster answer, else retained last-known ghosts
    /// (labeled), else honestly unknown. Unknown stays unknown.
    private var bots: [FleetBot] {
        let live = environment.bots(on: gatewayID)
        return live.isEmpty ? environment.cachedBotsByGateway[gatewayID] ?? [] : live
    }
    private var working: [FleetBot] {
        bots.filter { [.working, .thinking, .usingTool].contains($0.activity) && environment.botPresence(for: $0.route) == .reachable }
    }
    private var observed: Int {
        bots.filter { $0.activity != .unknown && environment.botPresence(for: $0.route) == .reachable }.count
    }

    var body: some View {
        if let gateway {
            List {
                identitySection(gateway)
                if needsAuth {
                    Section {
                        Button {
                            authGatewayID = gatewayID
                        } label: {
                            Label("Sign in to this gateway", systemImage: "key")
                        }
                        .accessibilityIdentifier("fleet.gateway-detail.signin.\(gatewayID.rawValue)")
                    } header: {
                        Text("Needs You")
                    } footer: {
                        Text("Authentication is required before this phone can connect.")
                    }
                }
                Section {
                    contextualConnectionControls
                }
                workingSection
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
            .navigationTitle(gateway.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $authGatewayID) { id in
                GatewayAuthSheet(environment: environment, gatewayID: id)
            }
            .alert("Connection action failed", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
            .accessibilityIdentifier("fleet.gateway-detail.\(gatewayID.rawValue)")
        }
    }

    // MARK: Identity + honest coverage (§8 items 1–2)

    private func identitySection(_ gateway: FleetGateway) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gateway.displayName).font(.headline)
                    Text(GatewayConnectionCopy.label(connectionState))
                        .font(.subheadline)
                        .foregroundStyle(connectionState == .connected ? FleetTheme.statusOnline : FleetTheme.textSecondary)
                    Text(gateway.endpoint.map(Redaction.redactedURL) ?? "Endpoint not configured")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("fleet.gateway-detail.identity.\(gatewayID.rawValue)")
            LabeledContent("Known Bots") {
                switch environment.rosterSnapshot?.outcome(for: gatewayID) {
                case .loaded(let count): Text("\(count)").font(.body.monospacedDigit())
                default:
                    Text(bots.isEmpty ? "Unknown" : "\(bots.count) · last known")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Active") {
                if observed == 0 {
                    Text("Unknown").foregroundStyle(.secondary)
                } else {
                    Text("\(working.count) active · \(observed) of \(bots.count) observed").font(.footnote)
                }
            }
            .accessibilityIdentifier("fleet.gateway-detail.activity-coverage")
            Text("Attention coverage is limited to observed Bots and Groups on this gateway.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Contextual connection controls (§8: Connect / Sign In / Retry)

    @ViewBuilder
    private var contextualConnectionControls: some View {
        // Primary contextual action only. Disconnect/Reconnect and full
        // diagnostics live under Connection — copy never says "stop machine
        // or Bots".
        switch connectionState {
        case .idle, .disconnected:
            Button {
                Task { await environment.connect(to: gatewayID) }
            } label: {
                Label("Connect", systemImage: "bolt")
            }
            .accessibilityIdentifier("fleet.gateway-detail.connect.\(gatewayID.rawValue)")
        case .connecting:
            Label("Connecting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .connected:
            NavigationLink(value: FleetScreen.gatewayConnection(gatewayID)) {
                Label("Connection", systemImage: "network")
            }
            .accessibilityIdentifier("fleet.gateway-detail.connection-link.\(gatewayID.rawValue)")
        case .failed(.authenticationRequired):
            Button {
                authGatewayID = gatewayID
            } label: {
                Label("Sign In", systemImage: "key")
            }
            .accessibilityIdentifier("fleet.gateway-detail.signin.\(gatewayID.rawValue)")
        case .failed:
            Button {
                Task { await environment.connect(to: gatewayID) }
            } label: {
                Label("Retry Connection", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("fleet.gateway-detail.retry.\(gatewayID.rawValue)")
        }
    }

    // MARK: Working here (§8 item 4 — max 3 known executing Bots)

    @ViewBuilder
    private var workingSection: some View {
        if !working.isEmpty {
            Section("Working here") {
                ForEach(working.prefix(3)) { bot in
                    NavigationLink(value: FleetScreen.botDetail(bot.route)) {
                        LabeledContent(bot.displayName, value: bot.activity.rawValue)
                    }
                    .accessibilityIdentifier("fleet.gateway-detail.working.\(bot.route.id)")
                }
                if working.count > 3 {
                    Text("+ \(working.count - 3) more")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Section {
                Text("Activity unknown — no current execution observations for this gateway.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Text("Working here") }
        }
    }

    private func resource(_ title: String, _ icon: String, _ screen: FleetScreen, _ key: String) -> some View {
        NavigationLink(value: screen) { Label(title, systemImage: icon) }
            .accessibilityIdentifier("fleet.gateway-detail.\(gatewayID.rawValue).\(key)")
    }
}

/// §8 connection-state vocabulary shared by the cockpit and Connection rows.
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

/// §8 child: Groups hosted on (or replicated into view for) one gateway.
struct GatewayGroupsView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    var body: some View {
        List {
            if environment.rooms(for: gatewayID).isEmpty {
                Text("No Groups observed on this gateway. Refresh Bots to check again.")
                    .foregroundStyle(.secondary)
            }
            ForEach(environment.rooms(for: gatewayID), id: \.id) { room in
                NavigationLink(value: FleetScreen.room(room.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                        Text(room.id.provenance == .desktopLegacy ? "Managed by Hermes Desktop · read only" : "Hosted Group")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("fleet.gateway-groups.row.\(room.id.key)")
            }
        }
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
    }
}
