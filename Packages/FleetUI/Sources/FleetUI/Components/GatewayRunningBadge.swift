import SwiftUI

/// P0-7: subtle secondary badge for `gateway_running` server truth — whether
/// this profile runs its OWN gateway process (a standing per-profile
/// listener). NEVER the primary online/offline signal: the Hermes gateway is
/// a profile multiplexer, so every listed profile is chat-reachable through
/// the owning gateway's shared connection regardless of this flag. Presence
/// comes from the owning gateway's roster outcome (see
/// `FleetRosterSnapshot.botPresence(on:)`); this badge is informational only.
///
/// Hidden when false (the multiplexer steady state — no visual noise for the
/// common case); a caption-size token-style chip when true.
public struct GatewayRunningBadge: View {
    private let isRunning: Bool

    public init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    public var body: some View {
        if isRunning {
            HStack(spacing: 3) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9, weight: .semibold))
                Text("Own gateway")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(FleetTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(FleetTheme.textSecondary.opacity(0.12))
            )
            .accessibilityLabel("Runs its own gateway process")
            .accessibilityIdentifier("fleet.bot.own-gateway-badge")
        }
    }
}
