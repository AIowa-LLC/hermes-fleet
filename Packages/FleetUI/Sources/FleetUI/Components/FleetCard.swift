import SwiftUI

/// V2 (Nous Direction A) — the base card surface: flat #16161A token surface
/// with a 1px #32373C hairline border, corner radius 16. Deliberately FLAT:
/// no shadow, no material, no glass, no gradient — the hairline IS the
/// structure (stark-canvas restraint is the design).
///
/// All screens build surfaces on this component so the card treatment stays
/// uniform.
public struct FleetCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public var body: some View {
        content
            .padding(FleetTheme.spacingLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colorSchemeContrast == .increased ? FleetTheme.surfaceIncreased : FleetTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                    .strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1)
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
