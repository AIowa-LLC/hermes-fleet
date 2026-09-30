import Foundation
import FleetCore

/// P0.2b — honest, specific copy for a user-presence check that did not
/// verify. Never silent: every non-verified result maps to a message that says
/// what happened and that nothing changed.
public enum PresenceFeedback {

    /// The inline message for a non-verified result, or `nil` when verified.
    public static func message(for result: PresenceResult, action: PresenceAction) -> String? {
        switch result {
        case .verified:
            return nil
        case .cancelled:
            return "Verification cancelled. \(nothingChanged(action))"
        case .failed:
            return "Verification failed. \(nothingChanged(action)) Try again."
        case .passcodeNotSet:
            return "This device has no passcode, so your identity can't be verified. "
                + "Set a device passcode in Settings, then try again. \(nothingChanged(action))"
        }
    }

    private static func nothingChanged(_ action: PresenceAction) -> String {
        switch action {
        case .approveOnce, .approveForSession, .approveAlways:
            return "Nothing was sent; the command stays blocked. You can still deny it."
        case .enableYolo:
            return "YOLO stays off."
        case .turnOffAppLock:
            return "App Lock stays on."
        case .enterSudoPassword, .enterSecret:
            return "Nothing was sent. You can still skip."
        }
    }
}
