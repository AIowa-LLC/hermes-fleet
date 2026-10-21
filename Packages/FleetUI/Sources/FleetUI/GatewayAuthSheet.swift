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
    @Environment(\.fleetTheme) private var theme
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
                        if strategy == .deviceCredential {
                            Text("Fleet Device (managed)").tag(GatewayAuthConfiguration.Strategy.deviceCredential)
                        }
                        Text("Sign in with OAuth").tag(GatewayAuthConfiguration.Strategy.oauthNative)
                    }
                    .accessibilityIdentifier("fleet.gateways.auth.strategy")
                    .disabled(strategy == .deviceCredential)

                    LabeledContent("Credential stored") {
                        Text(credentialStored ? "Yes" : "No")
                            .foregroundStyle(credentialStored ? theme.textPrimary : theme.textSecondary)
                    }
                } header: {
                    Text("Strategy")
                        .foregroundStyle(theme.textSecondary)
                } footer: {
                    Text("The credential itself lives in Keychain only and is never shown.")
                        .foregroundStyle(theme.textSecondary)
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
                    if credentialStored && strategy == .deviceCredential {
                        Text("This phone credential is managed by Fleet owner enrollment.")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    } else if credentialStored {
                        Button("Clear Stored Credential", role: .destructive) { clearCredential() }
                            .disabled(isBusy)
                            .accessibilityIdentifier("fleet.gateways.auth.clear-token")
                    }
                    if strategy == .oauthNative {
                        Button {
                            signInWithOAuth()
                        } label: {
                            if isBusy {
                                ProgressView()
                            } else {
                                Label(credentialStored ? "Sign In Again" : "Continue with OAuth", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("fleet.gateways.auth.oauth-sign-in")
                        Text("Sign-in opens the system browser. Tokens stay in Keychain and are never shown. If native sign-in is unsupported, canceled, or unavailable, choose another existing strategy above.")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityIdentifier("fleet.gateways.auth.oauth-hint")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(FleetTheme.statusDestructive)
                    } header: {
                        Text("Couldn't update sign-in")
                            .foregroundStyle(FleetTheme.statusDestructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
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
        .tint(theme.highlight)
        .interactiveDismissDisabled(isBusy)
    }

    private var needsTokenEntry: Bool {
        switch strategy {
        case .none: return false
        case .sessionToken, .bearerToken, .loopbackToken: return true
        case .usernamePassword, .deviceCredential, .oauthNative: return false
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

    private func signInWithOAuth() {
        isBusy = true
        errorText = nil
        Task {
            do {
                try await environment.signInWithNativeOAuth(for: gatewayID)
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
                strategy = .none
            } catch {
                errorText = GatewaysView.describe(error)
            }
            isBusy = false
        }
    }
}
