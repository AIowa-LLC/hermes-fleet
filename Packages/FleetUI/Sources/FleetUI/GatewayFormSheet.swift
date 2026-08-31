import SwiftUI
import FleetCore

/// Add / edit gateway form sheet (U2 registry management).
///
/// Presentation-only: holds typed field state while the sheet is open; on
/// Save it builds a `GatewayRegistration` plus an optional `GatewayCredential`
/// and hands both to the `onSave` seam callback, which routes them straight to
/// the registry + Keychain store. A credential, when entered, is passed by
/// value to the seam and never held, logged, or stored in the view layer
/// (spec §16/§29).
struct GatewayFormSheet: View {
    private let title: String
    private let saveButton: String
    /// Non-nil when editing an existing gateway (prefill).
    private let existing: FleetGateway?
    private let onSave: (GatewayRegistration, GatewayCredential?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var endpointText: String
    @State private var strategy: GatewayAuthConfiguration.Strategy
    /// Secure credential entry — only shown for token strategies; never echoed.
    @State private var tokenText: String
    /// Username/password entry — only shown for the username/password
    /// strategy; never echoed.
    @State private var usernameText: String
    @State private var passwordText: String
    @State private var isSaving = false
    /// Explicit user confirmation to send credentials in cleartext to a
    /// public (non-private/loopback) address — B2 save-gate. Never persisted.
    @State private var confirmsCleartextSend = false

    init(
        title: String,
        saveButton: String,
        initial: FleetGateway?,
        onSave: @escaping (GatewayRegistration, GatewayCredential?) async -> Void
    ) {
        self.title = title
        self.saveButton = saveButton
        self.existing = initial
        self.onSave = onSave
        _displayName = State(initialValue: initial?.displayName ?? "")
        _endpointText = State(initialValue: initial?.endpoint?.absoluteString ?? "")
        _strategy = State(initialValue: initial?.authConfiguration.strategy ?? .none)
        _tokenText = State(initialValue: "")
        _usernameText = State(initialValue: "")
        _passwordText = State(initialValue: "")
        _confirmsCleartextSend = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("Display Name", text: $displayName)
                        .accessibilityIdentifier("fleet.gateways.form.name")
                    TextField("Endpoint (http://host:port)", text: $endpointText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("fleet.gateways.form.endpoint")
                }

                if cleartextRisk {
                    // B2: prominent cleartext warning when the endpoint is
                    // http:// to a NON-private/loopback host — credentials
                    // would travel unencrypted to a public address. Saving is
                    // gated on explicit confirmation below.
                    Section {
                        Label {
                            Text("Password will be sent unencrypted to a public address.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(FleetTheme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(FleetTheme.accent)
                        }
                        .accessibilityIdentifier("fleet.gateways.form.cleartext-warning")

                        Toggle("I understand — connect anyway", isOn: $confirmsCleartextSend)
                            .accessibilityIdentifier("fleet.gateways.form.cleartext-confirm")
                    } header: {
                        Text("Security Warning")
                    }
                }

                Section("Authentication") {
                    Picker("Strategy", selection: $strategy) {
                        Text("None").tag(GatewayAuthConfiguration.Strategy.none)
                        Text("Session Token").tag(GatewayAuthConfiguration.Strategy.sessionToken)
                        Text("Bearer Token").tag(GatewayAuthConfiguration.Strategy.bearerToken)
                        Text("Loopback Token").tag(GatewayAuthConfiguration.Strategy.loopbackToken)
                        Text("Username & Password").tag(GatewayAuthConfiguration.Strategy.usernamePassword)
                    }
                    .accessibilityIdentifier("fleet.gateways.form.strategy")

                    if needsTokenEntry {
                        SecureField("Token (optional now, editable later)", text: $tokenText)
                            .textContentType(.password)
                            .accessibilityIdentifier("fleet.gateways.form.token")
                    }
                    if needsUsernamePasswordEntry {
                        TextField("Username", text: $usernameText)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("fleet.gateways.form.username")
                        SecureField("Password", text: $passwordText)
                            .textContentType(.password)
                            .accessibilityIdentifier("fleet.gateways.form.password")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButton) { save() }
                        .disabled(!isValid || isSaving)
                        .accessibilityIdentifier("fleet.gateways.form.save")
                }
            }
        }
        .tint(FleetTheme.accent)
    }

    /// Token strategies need a secure entry field. `.none` does not.
    private var needsTokenEntry: Bool {
        switch strategy {
        case .none: return false
        case .sessionToken, .bearerToken, .loopbackToken: return true
        case .usernamePassword: return false
        }
    }

    /// The username/password strategy needs username + password fields.
    private var needsUsernamePasswordEntry: Bool {
        strategy == .usernamePassword
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var endpointURL: URL? {
        guard let url = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        // P1-6: treat the endpoint as an ORIGIN — reject user-info
        // (user:pass@host) and strip query/fragment at the form boundary too,
        // so credential material never leaves the text field.
        return try? GatewayEndpoint.normalizedOrigin(from: url)
    }

    /// B2 cleartext risk: the endpoint is `http://` AND its host is NOT a
    /// private or loopback address — credentials would travel unencrypted to
    /// a public address. `https://` is never at risk. `PrivateNetwork` does
    /// the network-free classification (RFC1918/127./::1/.local/localhost).
    private var cleartextRisk: Bool {
        guard let url = endpointURL,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              !host.isEmpty else { return false }
        return !PrivateNetwork.isPrivateOrLoopbackHost(host)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && endpointURL != nil && (!cleartextRisk || confirmsCleartextSend)
    }

    private func save() {
        guard isValid, let endpoint = endpointURL else { return }
        isSaving = true
        let registration = GatewayRegistration(
            id: existing?.id,
            displayName: trimmedName,
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(
                strategy: strategy,
                credentialStored: existing?.authConfiguration.credentialStored ?? false
            )
        )
        // The credential for token strategies is the token itself; for the
        // username/password strategy it is the password with the username
        // attached (stored as one Keychain item — the authenticator reads
        // both halves). Never echoed by the view layer.
        let credential: GatewayCredential? = {
            if strategy == .usernamePassword {
                guard !usernameText.isEmpty, !passwordText.isEmpty else { return nil }
                return GatewayCredential(rawValue: passwordText, username: usernameText)
            }
            guard needsTokenEntry, !tokenText.isEmpty else { return nil }
            return GatewayCredential(rawValue: tokenText)
        }()

        Task {
            await onSave(registration, credential)
            isSaving = false
            dismiss()
        }
    }
}
