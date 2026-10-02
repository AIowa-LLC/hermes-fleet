import SwiftUI

/// Snapshot cover latch shared by the aggregate lock and each scene owner.
struct PrivacyShieldPolicy {
    private(set) var isEngaged = false

    mutating func reset() { isEngaged = false }

    mutating func handle(
        _ phase: ScenePhase,
        contentUnlocked: Bool,
        enabled: Bool,
        backgroundCoverIntent: Bool = false
    ) {
        guard enabled else { reset(); return }
        switch phase {
        case .active:
            reset()
        case .inactive:
            if contentUnlocked { isEngaged = true }
        case .background:
            if contentUnlocked || backgroundCoverIntent { isEngaged = true }
        @unknown default:
            break
        }
    }
}

/// A scene keeps its own cover until that scene becomes active or App Lock
/// is disabled. Changes in another scene cannot clear this latch.
struct ScenePrivacyShieldPolicy {
    private(set) var phase: ScenePhase = .active
    private var cover = PrivacyShieldPolicy()

    var isVisible: Bool { cover.isEngaged }

    mutating func handle(
        _ phase: ScenePhase,
        contentUnlocked: Bool,
        enabled: Bool,
        aggregateCoverIntent: Bool
    ) {
        self.phase = phase
        cover.handle(
            phase, contentUnlocked: contentUnlocked, enabled: enabled,
            backgroundCoverIntent: aggregateCoverIntent)
    }

    mutating func reconcile(
        contentUnlocked: Bool,
        enabled: Bool,
        aggregateCoverIntent: Bool
    ) {
        guard enabled else { cover.reset(); return }
        // Authentication can complete while an inactive system sheet is
        // dismissing. It must not newly arm a cover over that fresh unlock.
        // A background scene still needs protection if another scene unlocks.
        guard phase == .background else { return }
        cover.handle(
            .background, contentUnlocked: contentUnlocked, enabled: enabled,
            backgroundCoverIntent: aggregateCoverIntent)
    }
}
