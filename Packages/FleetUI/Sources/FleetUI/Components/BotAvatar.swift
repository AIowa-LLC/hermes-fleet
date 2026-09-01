import SwiftUI

/// U5 (Gold Fleet) — shared bot avatar: initials in a magenta-tinted rounded
/// square (the hero mock's bot avatar slot).
///
/// Extracted from the U4 dashboard row so the dashboard, the per-gateway bot
/// list, the union roster, and bot detail render IDENTICAL avatars from one
/// component. Initials derive from the real display name via
/// `FleetDashboardFormatting.avatarInitials` (letters only, "?\" fallback —
/// never fabricated imagery). Decorative: hidden from VoiceOver.
public struct BotAvatar: View {
    private let initials: String

    public init(displayName: String) {
        self.initials = FleetDashboardFormatting.avatarInitials(from: displayName)
    }

    public var body: some View {
        Text(initials)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(FleetTheme.accentMagenta)
            .frame(width: 34, height: 34)
            .background(FleetTheme.accentMagenta.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

#Preview("BotAvatar") {
    VStack(spacing: FleetTheme.spacingMd) {
        BotAvatar(displayName: "Researcher")
        BotAvatar(displayName: "MacBook Bot")
        BotAvatar(displayName: "123")
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
