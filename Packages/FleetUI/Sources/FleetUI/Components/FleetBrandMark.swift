import SwiftUI

/// The approved Hermes Fleet identity mark (`FleetWingMark` image set).
///
/// One shared view so About, first-run, and add-server surfaces never drift to
/// ad-hoc SF Symbols. The mark keeps its aspect ratio and uses the same rounded
/// clip as the first-run header (corner radius scales with `size`, equal to
/// `FleetTheme.radiusCard` at 72 pt).
///
/// Pass `decorative: true` when the app name is rendered next to the mark so
/// VoiceOver does not announce it twice.
struct FleetBrandMark: View {
    let size: CGFloat
    var decorative = false

    init(size: CGFloat = 72, decorative: Bool = false) {
        self.size = size
        self.decorative = decorative
    }

    static func cornerRadius(for size: CGFloat) -> CGFloat {
        FleetTheme.radiusCard * size / 72
    }

    var body: some View {
        let mark = Image("FleetWingMark", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius(for: size)))
        if decorative {
            mark.accessibilityHidden(true)
        } else {
            mark
                .accessibilityLabel("Hermes Fleet")
                .accessibilityIdentifier("fleet.brand-mark")
        }
    }
}
