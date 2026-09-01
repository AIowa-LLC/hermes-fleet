import Foundation
import Observation
import FleetCore

/// In-memory draft of an in-progress Add/Edit-Gateway form (P0-2).
///
/// Owned by `AppEnvironment` at the composition root, so it survives the H1
/// biometric lock and scenePhase teardown: `FleetRootView` swaps the entire
/// `NavigationStack` (including `GatewaysView` and the presented form sheet
/// with all its `@State`) for `AppLockView` on background + re-lock. The form
/// binds directly to this store, so every keystroke lands here first; when the
/// app is unlocked again `GatewaysView` re-presents the sheet and the user
/// returns exactly where they were (P0-2 acceptance).
///
/// SECURITY: in-memory ONLY — never persisted (no UserDefaults / Keychain /
/// files), never logged. The store deliberately mirrors the old form's
/// transient `@State` (secrets live here only while the sheet is open). It is
/// cleared on intentional Cancel and on successful Save so secret fields
/// (token / password) do not linger after the sheet closes.
@MainActor
@Observable
public final class GatewayFormDraftStore {
    /// Which sheet the draft belongs to (`nil` = no in-progress draft).
    public enum PendingSheet: Equatable {
        case add
        case edit(GatewayID)
    }

    public private(set) var pendingSheet: PendingSheet?

    // MARK: Field state (bound directly by GatewayFormSheet)

    public var displayName = ""
    public var endpointText = ""
    public var strategy: GatewayAuthConfiguration.Strategy = .none
    public var tokenText = ""
    public var usernameText = ""
    public var passwordText = ""
    public var confirmsCleartextSend = false
    /// P2-6 inline save-failure message (non-secret) — survives the lock too.
    public var saveError: String?

    /// Whether a form is mid-flight (used by `GatewaysView` to decide whether
    /// to re-present the sheet after an unlock).
    public var isInProgress: Bool { pendingSheet != nil }

    public init() {}

    /// Start a fresh draft, seeding non-secret fields from an existing gateway
    /// (edit prefill). Secrets always start empty.
    public func begin(pendingSheet: PendingSheet, initial: FleetGateway?) {
        self.pendingSheet = pendingSheet
        displayName = initial?.displayName ?? ""
        endpointText = initial?.endpoint?.absoluteString ?? ""
        strategy = initial?.authConfiguration.strategy ?? .none
        tokenText = ""
        usernameText = ""
        passwordText = ""
        confirmsCleartextSend = false
        saveError = nil
    }

    /// Wipe the draft (intentional Cancel or successful Save). Clears the
    /// secret fields too so credential material never lingers after the sheet
    /// closes.
    public func clear() {
        pendingSheet = nil
        displayName = ""
        endpointText = ""
        strategy = .none
        tokenText = ""
        usernameText = ""
        passwordText = ""
        confirmsCleartextSend = false
        saveError = nil
    }
}
