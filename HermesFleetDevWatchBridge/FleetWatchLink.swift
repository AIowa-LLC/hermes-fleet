import SwiftUI
import FleetCore
import FleetUI
import FleetWatchKit

/// Owns the phone side of the Watch link for the Fleet Dev app. It starts only
/// after the app is active, so nothing is observed or pushed before App Lock
/// has had its say, and it registers a Live Ops poll context so pending
/// approvals are observed while the link is up.
@MainActor
final class FleetWatchLink {
    private var service: WatchPhoneService?
    private weak var observedEnvironment: AppEnvironment?

    func scenePhaseChanged(_ phase: ScenePhase, environment: AppEnvironment, lock: AppLockController) {
        guard phase == .active else {
            service?.pushSnapshot()
            return
        }
        if service == nil {
            let backend = EnvironmentWatchBackend(environment: environment, lock: lock, flavor: .dev)
            let coordinator = WatchPhoneCoordinator(
                backend: backend, flavor: .dev,
                ledgerStore: FileWatchMessageLedgerStore(url: FileWatchMessageLedgerStore.defaultURL()))
            let service = WatchPhoneService(coordinator: coordinator, flavor: .dev)
            service.setObservingForWatch = { [weak environment] on in
                if on { environment?.liveOps.beginObserving(.watch) } else { environment?.liveOps.endObserving(.watch) }
            }
            service.start()
            self.service = service
            observedEnvironment = environment
        }
        service?.pushSnapshot()
    }
}
