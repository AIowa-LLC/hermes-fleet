import SwiftUI
import FleetCore

/// Setup runs on the Hermes computer. This sheet only observes gateway status.
struct LiveOpsSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let environment: AppEnvironment
    let gatewayID: GatewayID
    @State private var checking = false

    static let downloadURL = URL(string: "https://github.com/AIowa-LLC/hermes-fleet/releases/tag/fleet-liveops-v0.2.0")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("See Desktop runs and their subagents in Fleet by installing Fleet Live Reporting on the computer running Hermes.")
                    Text(environment.gateway(for: gatewayID)?.displayName ?? "Hermes gateway")
                        .font(.headline)
                }
                Section("1. Download on your computer") {
                    Link("Download Fleet Live Reporting", destination: Self.downloadURL)
                        .accessibilityIdentifier("fleet.liveOpsSetup.download")
                    ShareLink(item: Self.downloadURL) {
                        Label("Share setup link", systemImage: "square.and.arrow.up")
                    }
                    Text("Download Fleet-Live-Reporting-0.2.0.zip from the release page and extract it on your Hermes computer.")
                }
                Section("2. Install and choose profiles") {
                    Text("On Mac, open Setup.command. For Linux or a custom Hermes installation, follow the instructions included in the download. Other platforms use the manual instructions in the bundle.")
                    Text("Choose the profiles you want Fleet to observe, including the profile hosting your Fleet gateway. Setup preserves existing settings and saves a private backup before changing them.")
                }
                Section("3. Restart Hermes when idle") {
                    Text("Wait for running work to finish, then quit and reopen Hermes Desktop. If your Fleet gateway runs as a separate service, restart that service too.")
                    Text("Setup does not stop running work. Profiles started after installation will load reporting automatically.")
                }
                Section("4. Check the connection") {
                    LiveOpsReportingStatusView(environment: environment, gatewayID: gatewayID, offersSetup: false)
                    Button(checking ? "Checking…" : "Check reporting") {
                        checking = true
                        Task {
                            await environment.liveOps.checkReportingNow()
                            checking = false
                        }
                    }
                    .disabled(checking)
                    .accessibilityIdentifier("fleet.liveOpsSetup.check")
                    Text("Once connected, start a Desktop run in a selected profile and confirm it appears in Fleet. Connected reporting confirms that a backend is publishing; it does not prove every profile has been restarted.")
                }
                Section("About reporting") {
                    Text("The plugin reads live sessions and delegated activity in enabled Desktop and dashboard backends. It uses your gateway’s existing authentication. Messaging bots and standalone CLI runs are not covered.")
                    Text("It does not grant control of Desktop runs from the phone.")
                }
            }
            .navigationTitle("Set up Live Operations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .accessibilityIdentifier("fleet.liveOpsSetup")
        }
        .task {
            environment.liveOps.beginObserving(.setup(gatewayID))
            defer { environment.liveOps.endObserving(.setup(gatewayID)) }
            try? await Task.sleep(for: .seconds(3600 * 24))
        }
    }
}

/// Shared by Fleet and gateway details. Status comes from typed detection,
/// never a substring of display copy or the machine's connection state.
struct LiveOpsReportingStatusView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    var offersSetup = true
    @State private var showingSetup = false

    private var snapshot: LiveOpsGatewaySnapshot? {
        environment.liveOps.snapshot?.gateways.first { $0.gatewayID == gatewayID }
    }

    private var status: String {
        guard let snapshot else { return "Reporting has not been checked yet." }
        if snapshot.coverage == .authFailed { return "Sign in to the gateway to check live reporting." }
        if snapshot.coverage == .disconnected { return "Connect to the gateway to check live reporting." }
        switch snapshot.reportingSetup {
        case .required: return "Desktop activity needs Fleet Live Reporting on the Hermes computer."
        case .reporting(let count) where snapshot.coverage.isReporting:
            return "Live reporting connected · \(count) backend\(count == 1 ? "" : "s")"
        case .reporting, .unavailable: return "Live reporting is unavailable. Check that Hermes has restarted and the selected profiles are enabled."
        case .unknown: return snapshot.observationNote ?? "Reporting has not been checked yet."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text(status)
                .font(FleetTheme.secondaryFont)
                .accessibilityIdentifier("fleet.liveOpsReporting.status.\(gatewayID.rawValue)")
            if offersSetup {
                Button(snapshot?.reportingSetup == .required ? "Set up Live Operations" : "Live Operations setup") {
                    showingSetup = true
                }
                .accessibilityIdentifier("fleet.liveOpsReporting.setup.\(gatewayID.rawValue)")
            }
        }
        .sheet(isPresented: $showingSetup) {
            LiveOpsSetupView(environment: environment, gatewayID: gatewayID)
        }
    }
}
