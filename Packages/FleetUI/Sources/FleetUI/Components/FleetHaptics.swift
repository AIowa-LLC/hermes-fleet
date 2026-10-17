import SwiftUI

/// Shared haptic vocabulary for Fleet. Every haptic in FleetUI is expressed as
/// one of these cases and routed through `.fleetHaptic`; no view calls
/// `.sensoryFeedback` or UIKit feedback generators directly.
///
/// Haptics are trigger-based: fire them on a state change, never on appearance.
/// SwiftUI already honors the system haptic settings, so there is no in-app
/// toggle.
///
/// Vocabulary:
/// - `send`: a message or command was submitted (light impact).
/// - `success`: a local action such as a copy completed.
/// - `refreshComplete`: a pull-to-refresh finished without error.
/// - `pairingComplete`: a gateway was added to Fleet.
/// - `approve`: an approval decision was accepted by the gateway.
/// - `deny`: a denial was accepted by the gateway (medium impact, not an error).
/// - `warning`: the user should look at something before continuing.
/// - `failure`: a send, turn, or refresh ended in an error state.
/// - `selection`: a picker or slider value changed.
public enum FleetHaptic: CaseIterable, Sendable {
    case send
    case success
    case warning
    case failure
    case selection
    case approve
    case deny
    case refreshComplete
    case pairingComplete

    /// The SwiftUI feedback this haptic plays.
    public var feedback: SensoryFeedback {
        switch self {
        case .send:
            .impact(weight: .light)
        case .success, .refreshComplete, .pairingComplete, .approve:
            .success
        case .deny:
            .impact(weight: .medium)
        case .warning:
            .warning
        case .failure:
            .error
        case .selection:
            .selection
        }
    }
}

/// Trigger state for a pull-to-refresh. Call `record(failed:)` after the refresh
/// `await` returns; `.fleetHaptic` then plays `refreshComplete` or `failure`
/// once. Nothing fires on appearance.
public struct FleetRefreshOutcome: Equatable, Sendable {
    /// Changes on every recorded refresh so repeated outcomes still trigger.
    public private(set) var generation = 0
    public private(set) var lastFailed = false

    public init() {}

    public mutating func record(failed: Bool) {
        generation += 1
        lastFailed = failed
    }
}

public extension View {
    /// Plays `haptic` each time `trigger` changes.
    func fleetHaptic<T: Equatable>(_ haptic: FleetHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }

    /// Plays `haptic` when `trigger` changes and `condition(old, new)` is true.
    func fleetHaptic<T: Equatable>(
        _ haptic: FleetHaptic,
        trigger: T,
        condition: @escaping (T, T) -> Bool
    ) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger, condition: condition)
    }

    /// Plays `refreshComplete` or `failure` for each recorded pull-to-refresh.
    func fleetRefreshHaptics(_ outcome: FleetRefreshOutcome) -> some View {
        fleetHaptic(.refreshComplete, trigger: outcome) { _, new in !new.lastFailed }
            .fleetHaptic(.failure, trigger: outcome) { _, new in new.lastFailed }
    }
}
