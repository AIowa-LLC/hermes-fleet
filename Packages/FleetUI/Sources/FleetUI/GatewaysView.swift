import SwiftUI
import FleetCore

/// Gateways list — the U2 fleet cockpit root (registry management).
///
/// Reads the registered gateways from `AppEnvironment` (observable) and
/// exposes the full registry-management surface over the FleetCore
/// `GatewayRegistryManaging` seam: add / edit / remove, test connection
/// (reachable/unreachable per spec §13), and per-gateway auth-config entry
/// (M7 credential flow — Keychain-safe, the secret never transits the UI
/// model). Each row also keeps the U1 runtime-owned connect/disconnect/
/// reconnect lifecycle.
///
/// M14 theme: Black/White/Signal Red; status is icon + text (color is
/// reinforcement only), per the semantic status map.
public struct GatewaysView: View {
    private let environment: AppEnvironment
    private let lockController: AppLockController

    /// Presentation-only sheet state (no secrets stored here).
    @State private var presentedSheet: PresentedSheet?
    /// Error surfaced to the user from a registry operation (non-secret).
    @State private var operationError: String?

    enum PresentedSheet: Identifiable {
        case add
        case edit(FleetGateway)
        case auth(GatewayID)
        case settings
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let gateway): return "edit-\(gateway.id.rawValue)"
            case .auth(let id): return "auth-\(id.rawValue)"
            case .settings: return "settings"
            }
        }
    }

    public init(environment: AppEnvironment, lockController: AppLockController) {
        self.environment = environment
        self.lockController = lockController
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                emptyState
            } else {
                gatewayList
            }
        }
        .navigationTitle("Hermes Fleet")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    presentedSheet = .add
                } label: {
                    Label("Add Gateway", systemImage: "plus")
                }
                .accessibilityIdentifier("fleet.gateways.add")

                NavigationLink(value: FleetScreen.roster) {
                    Label("Roster", systemImage: "cpu")
                }
                .accessibilityIdentifier("fleet.gateways.roster")

                // H2: Connection health dashboard (per-gateway uptime /
                // reconnects / last-disconnect / ping RTT).
                NavigationLink(value: FleetScreen.health) {
                    Label("Health", systemImage: "heart.text.square")
                }
                .accessibilityIdentifier("fleet.gateways.health")

                Button {
                    Task { await environment.refreshRoster() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("fleet.gateways.refresh")
                .disabled(environment.isRefreshing)

                // H1 (R4): in-app Settings entry — hosts the App Lock toggle
                // (default ON). UI-only gate; Keychain untouched.
                Button {
                    presentedSheet = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("fleet.gateways.settings")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .add:
                GatewayFormSheet(
                    title: "Add Gateway",
                    saveButton: "Add",
                    initial: nil
                ) { registration, credential in
                    do {
                        _ = try await environment.addGateway(registration, credential: credential)
                    } catch {
                        operationError = Self.describe(error)
                    }
                }
            case .edit(let gateway):
                GatewayFormSheet(
                    title: "Edit Gateway",
                    saveButton: "Save",
                    initial: gateway
                ) { registration, credential in
                    do {
                        // Apply the edited display name / endpoint / strategy.
                        _ = try await environment.updateGateway(
                            gateway.id,
                            edits: GatewayEdit(
                                displayName: registration.displayName,
                                endpoint: registration.endpoint,
                                authConfiguration: registration.authConfiguration
                            )
                        )
                        // Store a newly-entered credential (Keychain-safe);
                        // nil keeps the registry's existing credential.
                        if let credential {
                            try await environment.saveCredential(credential, for: gateway.id)
                        }
                    } catch {
                        operationError = Self.describe(error)
                    }
                }
            case .auth(let id):
                GatewayAuthSheet(environment: environment, gatewayID: id)
            case .settings:
                AppLockSettingsView(controller: lockController)
            }
        }
        .alert("Gateway Error", isPresented: .init(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.gateways")
    }

    // MARK: States

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Gateways")
            } icon: {
                Image(systemName: "server.rack")
                    .foregroundStyle(FleetTheme.accent)
            }
        } description: {
            Text("Add your first Hermes gateway to see your fleet.")
        } actions: {
            Button("Add Gateway") {
                presentedSheet = .add
            }
            .buttonStyle(.borderedProminent)
            .tint(FleetTheme.accent)
        }
        .accessibilityIdentifier("fleet.gateways.empty")
    }

    private var gatewayList: some View {
        List(environment.gateways) { gateway in
            NavigationLink(value: FleetScreen.bots(gateway.id)) {
                GatewayRowView(environment: environment, gateway: gateway)
            }
            .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { try? await environment.removeGateway(gateway.id) }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue).remove")
            }
            .contextMenu {
                Button {
                    Task { await environment.connect(to: gateway.id) }
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                Button {
                    Task { await environment.disconnect(from: gateway.id) }
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
                Button {
                    Task { await environment.reconnect(to: gateway.id) }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                Divider()
                Button {
                    Task {
                        do {
                            try await environment.testConnection(to: gateway.id)
                        } catch {
                            operationError = Self.describe(error)
                        }
                    }
                } label: {
                    Label("Test Connection", systemImage: "network")
                }
                Button {
                    presentedSheet = .auth(gateway.id)
                } label: {
                    Label("Authentication", systemImage: "key")
                }
                Button {
                    presentedSheet = .edit(gateway)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
        .accessibilityIdentifier("fleet.gateways.list")
    }

    /// Non-secret description for a registry operation failure.
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}

/// One gateway row: identity + test-result §13 status + runtime connection
/// lifecycle badge.
private struct GatewayRowView: View {
    private let environment: AppEnvironment
    private let gateway: FleetGateway

    init(environment: AppEnvironment, gateway: FleetGateway) {
        self.environment = environment
        self.gateway = gateway
    }

    var body: some View {
        let state = environment.connectionStates[gateway.id] ?? .idle
        // At large Dynamic Type the full row (icon + text + text badge + menu)
        // can exceed the row width. ViewThatFits picks the first fitting
        // variant — the full row normally, and a compact row (no text badge,
        // status icon only) at AX sizes so the display name always gets the
        // space it needs (M14 a11y gate: text yields to controls).
        ViewThatFits(in: .horizontal) {
            fullRow(state: state)
            compactRow(state: state)
        }
    }

    private func fullRow(state: GatewayConnectionState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(gateway.endpoint?.absoluteString ?? gateway.id.rawValue)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if gateway.authConfiguration.credentialStored || gateway.authConfigured {
                    Label("Auth configured", systemImage: "key")
                        .font(.caption2)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel("Authentication configured")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)

            if environment.testingGatewayIDs.contains(gateway.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Testing connection")
            } else {
                ConnectionStateBadge(state: state)
                    .accessibilityElement(children: .combine)
                    .fixedSize()
            }

            rowMenu
        }
        .padding(.vertical, 2)
    }

    /// Compact variant for large Dynamic Type: name + endpoint + a status
    /// ICON only (no text badge), so the name still has room to wrap.
    private func compactRow(state: GatewayConnectionState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(gateway.endpoint?.absoluteString ?? gateway.id.rawValue)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)

            if environment.testingGatewayIDs.contains(gateway.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Testing connection")
            } else {
                Image(systemName: statusSymbol(state))
                    .foregroundStyle(statusColor(state))
                    .fixedSize()
                    .accessibilityLabel("Status: \(statusLabel(state))")
            }

            rowMenu
        }
        .padding(.vertical, 2)
    }

    private var rowMenu: some View {
        Menu {
            Button {
                Task { await environment.connect(to: gateway.id) }
            } label: {
                Label("Connect", systemImage: "bolt.fill")
            }
            Button {
                Task { await environment.disconnect(from: gateway.id) }
            } label: {
                Label("Disconnect", systemImage: "power")
            }
            Button {
                Task { await environment.reconnect(to: gateway.id) }
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Divider()
            Button {
                Task {
                    do {
                        try await environment.testConnection(to: gateway.id)
                    } catch {
                        // absent gateway → surfaced by the sheet caller path
                    }
                }
            } label: {
                Label("Test Connection", systemImage: "network")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(FleetTheme.textSecondary)
                .fixedSize()
        }
        .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue).menu")
    }

    private func statusSymbol(_ state: GatewayConnectionState) -> String {
        switch state {
        case .idle: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "wifi.slash"
        case .failed(let status):
            switch status {
            case .authenticationRequired: return "exclamationmark.circle.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .unsupported: return "xmark.octagon.fill"
            case .offline: return "wifi.slash"
            case .online, .connecting: return "circle"
            }
        }
    }

    private func statusColor(_ state: GatewayConnectionState) -> Color {
        switch state {
        case .failed(let status):
            switch status {
            case .authenticationRequired, .degraded, .unsupported:
                return FleetTheme.accent
            case .offline, .online, .connecting:
                return FleetTheme.textSecondary
            }
        case .idle, .connecting, .connected, .disconnected:
            return FleetTheme.textSecondary
        }
    }

    private func statusLabel(_ state: GatewayConnectionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let status): return statusText(status)
        }
    }

    private func statusText(_ status: GatewayStatus) -> String {
        switch status {
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Auth Required"
        case .offline: return "Unreachable"
        case .unsupported: return "Unsupported"
        }
    }
}

/// The §13 semantic status badge: icon + text, color as reinforcement only.
/// Renders the last test-connection result status when one exists (so a
/// failed probe shows Auth Required / Unreachable even without a live connect).
private struct ConnectionStateBadge: View {
    let state: GatewayConnectionState

    var body: some View {
        Label {
            Text(label)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let status): return statusText(status)
        }
    }

    private var symbol: String {
        switch state {
        case .idle: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "wifi.slash"
        case .failed(let status):
            switch status {
            case .authenticationRequired: return "exclamationmark.circle.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .unsupported: return "xmark.octagon.fill"
            case .offline: return "wifi.slash"
            case .online, .connecting: return "circle"
            }
        }
    }

    private var color: Color {
        switch state {
        case .failed(let status):
            switch status {
            case .authenticationRequired, .degraded, .unsupported:
                return FleetTheme.accent
            case .offline, .online, .connecting:
                return FleetTheme.textSecondary
            }
        case .idle, .connecting, .connected, .disconnected:
            return FleetTheme.textSecondary
        }
    }

    private func statusText(_ status: GatewayStatus) -> String {
        switch status {
        case .online: return "Online"
        case .connecting: return "Connecting…"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Auth Required"
        case .offline: return "Unreachable"
        case .unsupported: return "Unsupported"
        }
    }
}
