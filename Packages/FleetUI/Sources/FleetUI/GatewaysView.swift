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
    /// P1-8: the gateway awaiting destructive-removal confirmation.
    @State private var gatewayPendingRemoval: FleetGateway?
    /// P1-8: the most recently removed gateway, for a bounded undo.
    @State private var lastRemovedGateway: FleetGateway?

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
                // P2-6: let the form see save failures — it keeps the sheet
                // open, preserves the non-secret fields, and surfaces the error
                // inline for retry (the parent no longer swallows the error into
                // a post-dismiss alert that races the sheet).
                GatewayFormSheet(
                    title: "Add Gateway",
                    saveButton: "Add",
                    initial: nil
                ) { registration, credential in
                    _ = try await environment.addGateway(registration, credential: credential)
                }
            case .edit(let gateway):
                GatewayFormSheet(
                    title: "Edit Gateway",
                    saveButton: "Save",
                    initial: gateway
                ) { registration, credential in
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
        // P1-8: destructive-removal confirmation — a named alert explaining
        // that the stored credential is deleted with the gateway. Removal
        // only proceeds on explicit confirm. (Alert, not confirmationDialog:
        // its two buttons expose stable accessibility identifiers to XCUITest.)
        .alert(
            "Remove Gateway?",
            isPresented: .init(
                get: { gatewayPendingRemoval != nil },
                set: { if !$0 { gatewayPendingRemoval = nil } }
            )
        ) {
            Button("Remove Gateway", role: .destructive) {
                confirmRemoval()
            }
            .accessibilityIdentifier("fleet.gateways.remove.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("fleet.gateways.remove.cancel")
        } message: {
            Text("This removes \"\(gatewayPendingRemoval?.displayName ?? "")\" and deletes its stored credential from the Keychain.")
        }
        // P1-8: bounded undo for the most recent removal (registry only — the
        // credential is intentionally gone per the confirmation above).
        .alert(
            "Gateway Removed",
            isPresented: .init(
                get: { lastRemovedGateway != nil },
                set: { if !$0 { lastRemovedGateway = nil } }
            )
        ) {
            Button("Undo") { undoRemoval() }
                .accessibilityIdentifier("fleet.gateways.remove.undo")
            Button("OK", role: .cancel) {}
        } message: {
            Text("Undo restores \"\(lastRemovedGateway?.displayName ?? "")\" as a gateway (no stored credential).")
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
                    // P1-8: never remove on an unconfirmed swipe — require an
                    // explicit, named confirmation that explains credential
                    // deletion before the registry + Keychain are touched.
                    gatewayPendingRemoval = gateway
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

    // MARK: P1-8 — confirmed removal + bounded undo

    /// Execute the confirmed destructive removal. Surfaces any failure
    /// (including a Keychain credential-cleanup failure) instead of
    /// suppressing it, and offers a bounded undo on success.
    private func confirmRemoval() {
        guard let gateway = gatewayPendingRemoval else { return }
        gatewayPendingRemoval = nil
        Task {
            do {
                try await environment.removeGateway(gateway.id)
                lastRemovedGateway = gateway
            } catch {
                operationError = Self.describe(error)
            }
        }
    }

    /// Undo the most recent removal: re-register the gateway (registry only —
    /// the credential was intentionally deleted per the confirmation). Bounded
    /// to the last removed gateway.
    private func undoRemoval() {
        guard let gateway = lastRemovedGateway else { return }
        lastRemovedGateway = nil
        guard let endpoint = gateway.endpoint else {
            operationError = Self.describe(GatewayRegistryError.invalidEndpoint)
            return
        }
        Task {
            do {
                _ = try await environment.addGateway(GatewayRegistration(
                    id: gateway.id,
                    displayName: gateway.displayName,
                    endpoint: endpoint,
                    authConfiguration: gateway.authConfiguration
                ))
            } catch {
                operationError = Self.describe(error)
            }
        }
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
                Text(gateway.endpoint.map(Redaction.redactedURL) ?? gateway.id.rawValue)
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
                Text(gateway.endpoint.map(Redaction.redactedURL) ?? gateway.id.rawValue)
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
