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
    @State private var isSaving = false

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

                Section("Authentication") {
                    Picker("Strategy", selection: $strategy) {
                        Text("None").tag(GatewayAuthConfiguration.Strategy.none)
                        Text("Session Token").tag(GatewayAuthConfiguration.Strategy.sessionToken)
                        Text("Bearer Token").tag(GatewayAuthConfiguration.Strategy.bearerToken)
                        Text("Loopback Token").tag(GatewayAuthConfiguration.Strategy.loopbackToken)
                    }
                    .accessibilityIdentifier("fleet.gateways.form.strategy")

                    if needsTokenEntry {
                        SecureField("Token (optional now, editable later)", text: $tokenText)
                            .textContentType(.password)
                            .accessibilityIdentifier("fleet.gateways.form.token")
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
        }
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var endpointURL: URL? {
        guard let url = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && endpointURL != nil
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
        let token: GatewayCredential? = (needsTokenEntry && !tokenText.isEmpty)
            ? GatewayCredential(rawValue: tokenText)
            : nil

        Task {
            await onSave(registration, token)
            isSaving = false
            dismiss()
        }
    }
}
