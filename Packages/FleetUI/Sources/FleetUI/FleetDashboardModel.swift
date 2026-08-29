import Foundation
import Observation
import FleetCore

/// Presentation state for the fleet dashboard.
///
/// M0: an inert placeholder that proves the UI state-ownership pattern and the
/// FleetUI → FleetCore dependency. No gateway data is loaded yet; discovery and
/// live state land in later milestones.
@MainActor
@Observable
public final class FleetDashboardModel {
    public private(set) var gateways: [FleetGateway]
    public private(set) var isLoading = false

    public init(gateways: [FleetGateway] = []) {
        self.gateways = gateways
    }
}
