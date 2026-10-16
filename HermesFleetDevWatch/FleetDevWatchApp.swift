import SwiftUI
import FleetWatchKit

@main
struct FleetDevWatchApp: App {
    @State private var store = FleetDevWatchApp.makeStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .task { store.start() }
        }
    }

    @MainActor
    private static func makeStore() -> WatchStore {
        #if DEBUG
        if let scenario = MockFleetTransport.launchScenario {
            return WatchStore(transport: MockFleetTransport(scenario: scenario),
                              defaults: UserDefaults(suiteName: "fleet.watch.mock") ?? .standard,
                              outboxURL: FileManager.default.temporaryDirectory.appendingPathComponent("mock-outbox.json"))
        }
        #endif
        return WatchStore(transport: ConnectivityTransport(flavor: .dev))
    }
}
