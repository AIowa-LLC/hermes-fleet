import SwiftUI
import FleetCore
#if canImport(UIKit)
import UIKit
#endif

/// First-server enrollment. The routine path discovers the gateway's
/// password provider, signs in as its owner, then asks for a deliberate
/// confirmation before registering this phone.
public struct GatewayOnboardingView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let environment: AppEnvironment
    private let canDismiss: Bool

    private enum Page: Equatable { case address, signIn, review }
    @State private var page: Page = .address
    @State private var addressText = "https://"
    @State private var provider: OwnerIdentityProvider?
    @State private var username = ""
    @State private var password = ""
    @State private var authorization: OwnerAuthorization?
    @State private var metadata: OwnerConnectionMetadata?
    @State private var errorMessage: String?
    @State private var tlsFingerprint: SPKIFingerprint?
    @State private var isWorking = false
    @State private var isShowingAdvancedForm = false
    @State private var flowGeneration = 0
    @State private var adoptionInFlight = false
    @State private var ownerEnrollmentTransactionID: UUID?
    @State private var hasCanceledPendingRequest = false
    @FocusState private var focusedField: Field?

    private enum Field { case address, username, password }
    private struct TransactionLease {
        let id: UUID
        let ownsTransaction: Bool
    }

    public init(environment: AppEnvironment, canDismiss: Bool = false) {
        self.environment = environment
        self.canDismiss = canDismiss
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    header
                    if isBlockedByEarlierTransaction || hasCanceledPendingRequest {
                        FleetCard {
                            Text("A canceled server request is still finishing or being cleaned up. You can start again when it settles.")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityIdentifier("fleet.onboarding.request-pending")
                        }
                    }
                    switch page {
                    case .address: addressPage
                    case .signIn: signInPage
                    case .review: reviewPage
                    }
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    if let tlsFingerprint {
                        tlsReviewCard(tlsFingerprint)
                    }
                    advancedSetupButton
                }
                .padding(FleetTheme.spacingXl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Connect a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: { dismiss() })
                            .accessibilityIdentifier("fleet.onboarding.dismiss")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel", action: cancelSignIn)
                            .disabled(page == .address && !isWorking)
                            .accessibilityIdentifier("fleet.onboarding.cancel-flow")
                    }
                }
                if page != .address {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left", action: goBack)
                            .accessibilityIdentifier("fleet.onboarding.back")
                    }
                }
            }
        }
        .tint(theme.highlight)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            invalidateFlow()
            if page == .review { page = .signIn }
        }
        .onDisappear {
            // A successful first-run adoption removes this view as the root
            // switches into Fleet. Preserve that completion only after the
            // gateway is in the registry. Dismissible add-server sheets and
            // incomplete adoption are still invalidated.
            let completedFirstRunAdoption = adoptionInFlight
                && !canDismiss
                && metadata.map { expected in environment.gateways.contains(where: { $0.id == expected.gatewayID }) } == true
            if !completedFirstRunAdoption { invalidateFlow() }
        }
        .sheet(isPresented: $isShowingAdvancedForm) {
            GatewayFormSheet(
                title: "Advanced Gateway Setup",
                saveButton: "Add",
                initial: nil,
                draftStore: environment.gatewayFormDraft
            ) { registration, credential, confirmsTLSFirstUse in
                _ = try await environment.addGateway(
                    registration,
                    credential: credential,
                    confirmsTLSFirstUse: confirmsTLSFirstUse)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 38))
                .foregroundStyle(theme.highlight)
                .accessibilityHidden(true)
            Text("Hermes Fleet")
                .font(FleetTheme.titleFont)
                .foregroundStyle(theme.highlight)
                .accessibilityIdentifier("fleet.onboarding.title")
            Text(canDismiss ? "Connect another Hermes server" : "Connect your first Hermes server")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.onboarding.headline")
            Text("You’ll need a running Hermes server reachable at an HTTPS address and an owner account for that server. Fleet will use the server’s detected sign-in provider and choose a display name automatically.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.onboarding.prerequisite")
        }
    }

    private var addressPage: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                Text("Server address")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                TextField("https://hermes.example.com", text: $addressText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focusedField, equals: .address)
                    .accessibilityIdentifier("fleet.onboarding.address")
                    .disabled(isWorking || isBlockedByEarlierTransaction)
                    .onSubmit { Task { await discoverProvider() } }
                Button(action: { Task { await discoverProvider() } }) {
                    HStack {
                        if isWorking { ProgressView().tint(theme.onHighlight) }
                        Text(isWorking ? "Checking server…" : "Continue")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.highlight)
                .foregroundStyle(theme.onHighlight)
                .disabled(isWorking || isBlockedByEarlierTransaction)
                .accessibilityIdentifier("fleet.onboarding.continue")
            }
        }
    }

    private var signInPage: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    Text("Sign in to your server")
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(theme.textPrimary)
                    Text(provider?.displayName ?? "Provider detected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.highlight)
                        .accessibilityIdentifier("fleet.onboarding.provider")
                }

                if provider?.supportsPassword == true {
                    TextField("Owner username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .accessibilityIdentifier("fleet.onboarding.username")
                        .disabled(isWorking || isBlockedByEarlierTransaction)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("fleet.onboarding.password")
                        .disabled(isWorking || isBlockedByEarlierTransaction)
                    Button(action: { Task { await signIn() } }) {
                        HStack {
                            if isWorking { ProgressView().tint(theme.onHighlight) }
                            Text(isWorking ? "Signing in…" : "Sign in")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.highlight)
                    .foregroundStyle(theme.onHighlight)
                    .disabled(isWorking || isBlockedByEarlierTransaction || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("fleet.onboarding.sign-in")
                } else {
                    Text("This server’s sign-in provider is not supported on this phone yet. You can retry provider detection, edit the address, or use advanced gateway setup.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.onboarding.unsupported-provider")
                    Button("Retry provider detection", action: { Task { await discoverProvider() } })
                        .disabled(isWorking || isBlockedByEarlierTransaction)
                        .accessibilityIdentifier("fleet.onboarding.retry")
                }

                Button("Cancel sign-in", action: cancelSignIn)
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.onboarding.cancel")
            }
        }
    }

    private var reviewPage: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                Text("Ready to connect")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("fleet.onboarding.review-title")
                if let metadata {
                    Label(metadata.displayName, systemImage: "server.rack")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("fleet.onboarding.server-name")
                    Text(metadata.origin.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                    Text("Fleet will register this phone with the server using an automatic device name. You can manage this connection later in Fleet.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("With fleet operator access, Fleet can chat with Hermes, run and review work, and manage agents on this server with the same account level access you just approved.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.onboarding.permission-explanation")
                }
                Button(action: { Task { await connectThisPhone() } }) {
                    HStack {
                        if isWorking { ProgressView().tint(theme.onHighlight) }
                        Text(isWorking ? "Connecting…" : "Connect this phone")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.highlight)
                .foregroundStyle(theme.onHighlight)
                .disabled(isWorking || isBlockedByEarlierTransaction)
                .accessibilityIdentifier("fleet.onboarding.connect-phone")
                Button("Cancel", action: cancelSignIn)
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.onboarding.cancel")
            }
        }
    }

    private var advancedSetupButton: some View {
        Button {
            cancelSignIn()
            environment.gatewayFormDraft.begin(pendingSheet: .add, initial: nil)
            isShowingAdvancedForm = true
        } label: {
            Label("Advanced gateway setup", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isWorking || isBlockedByEarlierTransaction)
        .accessibilityIdentifier("fleet.onboarding.advanced")
    }

    private func errorCard(_ message: String) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Label("Couldn’t connect", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.highlight)
                Text(message)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.onboarding.error")
                if page == .review {
                    Button("Retry connection", action: { Task { await connectThisPhone() } })
                        .disabled(isWorking || isBlockedByEarlierTransaction)
                        .accessibilityIdentifier("fleet.onboarding.retry")
                } else if page == .signIn {
                    Button("Try sign in again", action: { Task { await signIn() } })
                        .disabled(isWorking || isBlockedByEarlierTransaction || password.isEmpty)
                        .accessibilityIdentifier("fleet.onboarding.retry")
                } else {
                    Button("Retry", action: { Task { await discoverProvider() } })
                        .disabled(isWorking || isBlockedByEarlierTransaction)
                        .accessibilityIdentifier("fleet.onboarding.retry")
                }
            }
        }
    }

    private func tlsReviewCard(_ fingerprint: SPKIFingerprint) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Label("Review gateway security key", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Only continue if this fingerprint was provided by the gateway owner through a trusted channel.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fingerprint.base64String)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("fleet.onboarding.tls-fingerprint")
                Button("Trust this key and retry", action: { Task { await approveTLSAndRetry() } })
                    .disabled(isWorking || isBlockedByEarlierTransaction)
                    .accessibilityIdentifier("fleet.onboarding.tls-approve")
                Button("Edit address", action: cancelSignIn)
                    .disabled(isWorking || isBlockedByEarlierTransaction)
                    .accessibilityIdentifier("fleet.onboarding.tls-edit")
            }
        }
    }

    private func discoverProvider() async {
        let generation = flowGeneration
        errorMessage = nil
        tlsFingerprint = nil
        guard let service = environment.ownerEnrollment,
              let address = httpsAddress(addressText) else {
            errorMessage = environment.ownerEnrollment == nil
                ? "Owner enrollment is unavailable in this build. Use advanced gateway setup."
                : OwnerEnrollmentError.insecureTransport.localizedDescription
            return
        }
        guard !environment.gateways.contains(where: { sameOrigin($0.endpoint, address) }) else {
            errorMessage = "This server is already connected. Return to Fleet to open it."
            return
        }
        guard let transaction = beginOwnerEnrollmentOperation() else { return }
        isWorking = true
        defer {
            isWorking = false
            finishOwnerEnrollmentOperation(transaction)
        }
        do {
            let found = try await service.discoverProviders(at: address)
            guard isCurrent(generation) else { return }
            guard !found.isEmpty else {
                errorMessage = "No supported sign-in provider was found on this server. Check the address or use advanced gateway setup."
                return
            }
            let passwordProviders = found.filter(\.supportsPassword)
            guard let detected = passwordProviders.first else {
                provider = found.first
                page = .signIn
                errorMessage = "This server’s sign-in provider is not supported on this phone yet."
                return
            }
            provider = detected
            page = .signIn
            focusedField = .username
        } catch {
            guard isCurrent(generation) else { return }
            if let enrollmentError = error as? OwnerEnrollmentError,
               case .tlsFirstUse(let fingerprint) = enrollmentError {
                tlsFingerprint = fingerprint
            } else {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    private func approveTLSAndRetry() async {
        let generation = flowGeneration
        guard let service = environment.ownerEnrollment,
              let address = httpsAddress(addressText),
              let fingerprint = tlsFingerprint else { return }
        guard let transaction = beginOwnerEnrollmentOperation() else { return }
        isWorking = true
        defer {
            isWorking = false
            finishOwnerEnrollmentOperation(transaction)
        }
        do {
            try await service.approveTLSFirstUse(at: address, fingerprint: fingerprint)
            guard isCurrent(generation) else { return }
            tlsFingerprint = nil
            await discoverProvider()
        } catch {
            guard isCurrent(generation) else { return }
            errorMessage = displayMessage(for: error)
            tlsFingerprint = nil
        }
    }

    private func signIn() async {
        let generation = flowGeneration
        errorMessage = nil
        tlsFingerprint = nil
        guard let service = environment.ownerEnrollment,
              let address = httpsAddress(addressText),
              let provider, provider.supportsPassword else { return }
        guard let transaction = beginOwnerEnrollmentOperation() else { return }
        isWorking = true
        defer {
            isWorking = false
            finishOwnerEnrollmentOperation(transaction)
        }
        do {
            let signedIn = try await service.signIn(
                at: address,
                providerID: provider.id,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            guard isCurrent(generation) else { return }
            username = ""
            password = ""
            let server = try await service.inspectConnection(at: address, authorization: signedIn)
            guard isCurrent(generation) else { return }
            guard server.origin == address || sameOrigin(server.origin, address) else {
                errorMessage = "The server returned a different address. Edit the address and try again."
                return
            }
            guard Set(server.scopes) == ["fleet:operator"] else {
                errorMessage = "This server requested permissions Fleet can’t safely use on this phone. No connection was added."
                return
            }
            if environment.gateways.contains(where: { $0.id == server.gatewayID || sameOrigin($0.endpoint, server.origin) }) {
                errorMessage = "This server is already connected. Return to Fleet to open it."
                return
            }
            authorization = signedIn
            metadata = server
            page = .review
            errorMessage = nil
            focusedField = nil
        } catch {
            guard isCurrent(generation) else { return }
            errorMessage = displayMessage(for: error)
        }
    }

    private func connectThisPhone() async {
        let generation = flowGeneration
        errorMessage = nil
        tlsFingerprint = nil
        guard let service = environment.ownerEnrollment,
              let metadata,
              let authorization else { return }
        guard let transaction = beginOwnerEnrollmentOperation() else { return }
        isWorking = true
        defer {
            isWorking = false
            finishOwnerEnrollmentOperation(transaction)
        }
        do {
            let device = try await service.enrollDevice(
                at: metadata.origin,
                authorization: authorization,
                deviceName: automaticDeviceName,
                deviceModel: deviceModel)
            guard isCurrent(generation) else {
                await rollbackEnrollment(
                    service: service,
                    at: metadata.origin,
                    authorization: authorization,
                    deviceID: device.deviceID,
                    gatewayID: device.gatewayID,
                    message: "Phone enrollment finished after setup was interrupted. Cleanup is pending; retry it in Settings."
                )
                return
            }
            guard device.gatewayID == metadata.gatewayID,
                  Set(device.scopes) == ["fleet:operator"] else {
                do {
                    try await service.cancelEnrollment(
                        at: metadata.origin,
                        authorization: authorization,
                        deviceID: device.deviceID,
                        gatewayID: device.gatewayID)
                } catch {
                    await recordCleanupRecovery(
                        service: service,
                        at: metadata.origin,
                        authorization: authorization,
                        deviceID: device.deviceID,
                        gatewayID: device.gatewayID,
                        message: "The server returned permissions Fleet can’t use. Removal of this phone is pending; retry cleanup in Settings."
                    )
                    errorMessage = "The server returned permissions Fleet can’t use. Removal of this phone is pending; retry cleanup in Settings."
                    return
                }
                errorMessage = "The server returned permissions Fleet can’t safely use on this phone. No connection was added."
                return
            }
            do {
                adoptionInFlight = true
                defer { adoptionInFlight = false }
                try await environment.adoptOwnerEnrollment(metadata: metadata, device: device)
                guard isCurrent(generation) else {
                    await rollbackEnrollment(
                        service: service,
                        at: metadata.origin,
                        authorization: authorization,
                        deviceID: device.deviceID,
                        gatewayID: device.gatewayID,
                        registeredGatewayID: metadata.gatewayID,
                        message: "Phone enrollment finished after setup was interrupted. Cleanup is pending; retry it in Settings."
                    )
                    return
                }
                self.authorization = nil
                if canDismiss { dismiss() }
            } catch {
                await rollbackEnrollment(
                    service: service,
                    at: metadata.origin,
                    authorization: authorization,
                    deviceID: device.deviceID,
                    gatewayID: device.gatewayID,
                    registeredGatewayID: metadata.gatewayID,
                    message: "The server enrolled this phone, but Fleet couldn’t finish adding it. Cleanup is pending; retry it in Settings."
                )
                if environment.ownerEnrollmentRecoveryMessage != nil {
                    errorMessage = "The server enrolled this phone, but Fleet couldn’t finish adding it. Cleanup is pending; retry it in Settings."
                    return
                }
                throw error
            }
        } catch {
            guard isCurrent(generation) else { return }
            errorMessage = displayMessage(for: error)
        }
    }

    private var automaticDeviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "iPhone"
        #endif
    }

    private var deviceModel: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        "Apple device"
        #endif
    }

    private func httpsAddress(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return nil }
        return url
    }

    private func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private var isBlockedByEarlierTransaction: Bool {
        if hasCanceledPendingRequest { return true }
        guard let environmentTransaction = environment.ownerEnrollmentTransactionID else { return false }
        return environmentTransaction != ownerEnrollmentTransactionID
    }

    private func beginOwnerEnrollmentOperation() -> TransactionLease? {
        if let ownerEnrollmentTransactionID {
            return TransactionLease(id: ownerEnrollmentTransactionID, ownsTransaction: false)
        }
        guard let transactionID = environment.beginOwnerEnrollmentTransaction() else {
            errorMessage = "A canceled server request is still finishing or being cleaned up. Try again when it settles."
            return nil
        }
        ownerEnrollmentTransactionID = transactionID
        return TransactionLease(id: transactionID, ownsTransaction: true)
    }

    private func finishOwnerEnrollmentOperation(_ transaction: TransactionLease) {
        guard transaction.ownsTransaction else { return }
        environment.endOwnerEnrollmentTransaction(transaction.id)
        if ownerEnrollmentTransactionID == transaction.id {
            ownerEnrollmentTransactionID = nil
            hasCanceledPendingRequest = false
        }
    }

    private func rollbackEnrollment(
        service: any OwnerEnrollmentProviding,
        at address: URL,
        authorization: OwnerAuthorization,
        deviceID: String,
        gatewayID: GatewayID,
        registeredGatewayID: GatewayID? = nil,
        message: String
    ) async {
        do {
            // The owner service needs the newly stored device credential to
            // revoke remotely. Remove the local registry entry only after the
            // remote cancellation succeeds.
            try await service.cancelEnrollment(
                at: address,
                authorization: authorization,
                deviceID: deviceID,
                gatewayID: gatewayID)
            if let registeredGatewayID,
               environment.gateways.contains(where: { $0.id == registeredGatewayID }) {
                try await environment.removeGateway(registeredGatewayID)
            }
        } catch {
            await recordCleanupRecovery(
                service: service,
                at: address,
                authorization: authorization,
                deviceID: deviceID,
                gatewayID: gatewayID,
                registeredGatewayID: registeredGatewayID,
                message: message)
        }
    }

    private func recordCleanupRecovery(
        service: any OwnerEnrollmentProviding,
        at address: URL,
        authorization: OwnerAuthorization,
        deviceID: String,
        gatewayID: GatewayID,
        registeredGatewayID: GatewayID? = nil,
        message: String
    ) async {
        await environment.recordOwnerEnrollmentRecovery(message: message) { [environment] in
            try await service.cancelEnrollment(
                at: address,
                authorization: authorization,
                deviceID: deviceID,
                gatewayID: gatewayID)
            if let registeredGatewayID,
               environment.gateways.contains(where: { $0.id == registeredGatewayID }) {
                try await environment.removeGateway(registeredGatewayID)
            }
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let enrollmentError = error as? OwnerEnrollmentError {
            if case .unauthorized = enrollmentError {
                return "That username or password was not accepted. Check your owner account details and try again."
            }
            return enrollmentError.localizedDescription
        }
        return "Sign-in could not be completed. Check your details and try again."
    }

    private func goBack() {
        errorMessage = nil
        if page == .review {
            invalidateFlow()
            page = .signIn
            authorization = nil
            metadata = nil
        } else {
            cancelSignIn()
        }
    }

    private func cancelSignIn() {
        invalidateFlow()
        page = .address
        provider = nil
        username = ""
        password = ""
        authorization = nil
        metadata = nil
        errorMessage = nil
        focusedField = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == flowGeneration && !Task.isCancelled
    }

    private func invalidateFlow() {
        flowGeneration &+= 1
        hasCanceledPendingRequest = ownerEnrollmentTransactionID != nil
        username = ""
        password = ""
        authorization = nil
    }
}
