import SwiftUI

/// U2 (Gold Fleet) — the base card surface: token surface color, 1px border
/// at ~8%, corner radius 16. Flat design: no shadow, no material.
///
/// All re-skin cards (U3–U7) build screen surfaces on this component so the
/// card treatment stays uniform.
public struct FleetCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(FleetTheme.spacingLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                    .strokeBorder(FleetTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
    }
}

#Preview("FleetCard") {
    FleetCard {
        Text("Card content")
            .font(FleetTheme.secondaryFont)
            .foregroundStyle(FleetTheme.textSecondary)
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
