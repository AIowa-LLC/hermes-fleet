import SwiftUI

/// V2 (Nous Direction A) — shared bot avatar: mono initials on a flat
/// hairline-bordered square. No tinted fill, no shadow, no gradient — the
/// avatar reads as a terminal identity chip, not a sticker.
///
/// Extracted from the U4 dashboard row so the dashboard, the per-gateway bot
/// list, the union roster, and bot detail render IDENTICAL avatars from one
/// component. Initials derive from the real display name via
/// `FleetDashboardFormatting.avatarInitials` (letters only, "?\"" fallback —
/// never fabricated imagery). Decorative: hidden from VoiceOver.
public struct BotAvatar: View {
    private let initials: String

    public init(displayName: String) {
        self.initials = FleetDashboardFormatting.avatarInitials(from: displayName)
    }

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public var body: some View {
        Text(initials)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(FleetTheme.accent)
            .frame(width: Self.side, height: Self.side)
            .background(LinearGradient(colors: [FleetTheme.accent.opacity(0.18), FleetTheme.surfaceElevated], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    /// Avatar square side (pt).
    static let side: CGFloat = 44
    /// Initials point size (mono).
    static let fontSize: CGFloat = 13
    /// Corner radius (softer than the 16pt card radius).
    static let cornerRadius: CGFloat = 15
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
