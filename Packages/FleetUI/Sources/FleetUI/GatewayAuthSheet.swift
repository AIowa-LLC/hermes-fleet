import SwiftUI
import FleetCore

/// Per-gateway authentication configuration sheet (U2 registry management,
/// M7 auth-config entry).
///
/// Two surfaces over the FleetCore `GatewayRegistryManaging` seam:
/// - the auth **strategy** (none / session token / bearer / loopback), saved
///   via `updateGateway(edits:)` — non-secret;
/// - the **credential** (the secret), stored/cleared via `saveCredential` /
///   `clearCredential` — Keychain only, never held or echoed by the view
///   layer (spec §16/§29).
struct GatewayAuthSheet: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID

    @Environment(\.dismiss) private var dismiss
    @State private var strategy: GatewayAuthConfiguration.Strategy
    @State private var tokenText: String
    @State private var usernameText: String
    @State private var passwordText: String
    @State private var credentialStored = false
    @State private var isBusy = false
    @State private var errorText: String?

    init(environment: AppEnvironment, gatewayID: GatewayID) {
        self.environment = environment
        self.gatewayID = gatewayID
        let gateway = environment.gateway(for: gatewayID)
        _strategy = State(initialValue: gateway?.authConfiguration.strategy ?? .none)
        _credentialStored = State(initialValue: gateway?.authConfiguration.credentialStored ?? false)
        _tokenText = State(initialValue: "")
        _usernameText = State(initialValue: "")
        _passwordText = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Strategy", selection: $strategy) {
                        Text("None").tag(GatewayAuthConfiguration.Strategy.none)
                        Text("Session Token").tag(GatewayAuthConfiguration.Strategy.sessionToken)
                        Text("Bearer Token").tag(GatewayAuthConfiguration.Strategy.bearerToken)
                        Text("Loopback Token").tag(GatewayAuthConfiguration.Strategy.loopbackToken)
                        Text("Username & Password").tag(GatewayAuthConfiguration.Strategy.usernamePassword)
                    }
                    .accessibilityIdentifier("fleet.gateways.auth.strategy")

                    LabeledContent("Credential stored") {
                        Text(credentialStored ? "Yes" : "No")
                            .foregroundStyle(credentialStored ? FleetTheme.textPrimary : FleetTheme.textSecondary)
                    }
                } header: {
                    Text("Strategy")
                        .foregroundStyle(FleetTheme.textSecondary)
                } footer: {
                    Text("The credential itself lives in Keychain only and is never shown.")
                        .foregroundStyle(FleetTheme.textSecondary)
                }

                Section("Credential") {
                    if needsTokenEntry {
                        SecureField("New token", text: $tokenText)
                            .textContentType(.password)
                            .accessibilityIdentifier("fleet.gateways.auth.token")
                        Button("Save Token") { saveToken() }
                            .disabled(tokenText.isEmpty || isBusy)
                            .accessibilityIdentifier("fleet.gateways.auth.save-token")
                    }
                    if needsUsernamePasswordEntry {
                        TextField("Username", text: $usernameText)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("fleet.gateways.auth.username")
                        SecureField("Password", text: $passwordText)
                            .textContentType(.password)
                            .accessibilityIdentifier("fleet.gateways.auth.password")
                        Button("Save Username & Password") { saveUsernamePassword() }
                            .disabled(usernameText.isEmpty || passwordText.isEmpty || isBusy)
                            .accessibilityIdentifier("fleet.gateways.auth.save-username-password")
                    }
                    if credentialStored {
                        Button("Clear Stored Credential", role: .destructive) { clearCredential() }
                            .disabled(isBusy)
                            .accessibilityIdentifier("fleet.gateways.auth.clear-token")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(FleetTheme.statusDestructive)
                    } header: {
                        Text("Error")
                            .foregroundStyle(FleetTheme.statusDestructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FleetTheme.background.ignoresSafeArea())
            .navigationTitle("Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: strategy) { _, newValue in
                Task { await saveStrategy(newValue) }
            }
        }
        .tint(FleetTheme.accent)
        .interactiveDismissDisabled(isBusy)
    }

    private var needsTokenEntry: Bool {
        switch strategy {
        case .none: return false
        case .sessionToken, .bearerToken, .loopbackToken: return true
        case .usernamePassword: return false
        }
    }

    private var needsUsernamePasswordEntry: Bool {
        strategy == .usernamePassword
    }

    private func saveStrategy(_ newValue: GatewayAuthConfiguration.Strategy) {
        isBusy = true
        errorText = nil
        Task {
            do {
                _ = try await environment.updateGateway(
                    gatewayID,
                    edits: GatewayEdit(authConfiguration: GatewayAuthConfiguration(
                        strategy: newValue,
                        credentialStored: credentialStored
                    ))
                )
            } catch {
                errorText = GatewaysView.describe(error)
            }
            isBusy = false
        }
    }

    private func saveToken() {
        isBusy = true
        errorText = nil
        let token = GatewayCredential(rawValue: tokenText)
        Task {
            do {
                try await environment.saveCredential(token, for: gatewayID)
                tokenText = ""
                credentialStored = true
            } catch {
                errorText = GatewaysView.describe(error)
            }
            isBusy = false
        }
    }

    private func saveUsernamePassword() {
        isBusy = true
        errorText = nil
        // Password rides as the secret half; username travels inside the same
        // redacted credential so the login flow can present both.
        let credential = GatewayCredential(rawValue: passwordText, username: usernameText)
        Task {
            do {
                try await environment.saveCredential(credential, for: gatewayID)
                usernameText = ""
                passwordText = ""
                credentialStored = true
            } catch {
                errorText = GatewaysView.describe(error)
            }
            isBusy = false
        }
    }

    private func clearCredential() {
        isBusy = true
        errorText = nil
        Task {
            do {
                try await environment.clearCredential(for: gatewayID)
                credentialStored = false
            } catch {
                errorText = GatewaysView.describe(error)
            }
            isBusy = false
        }
    }
}
