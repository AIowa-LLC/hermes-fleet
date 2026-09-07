import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pixel-hairline height (1pt on non-Retina, 0.5pt on Retina+). UIKit-only;
/// macOS host-side builds get the fixed 0.5pt convenience value.
@available(iOS 13.0, macOS 10.15, *)
private var hairlineHeight: CGFloat {
    #if canImport(UIKit)
    1 / UIScreen.main.scale
    #else
    0.5
    #endif
}

/// Terminal-style `KEY:` metadata row with a muted monospaced key, primary
/// monospaced value, and optional hairline divider.
public struct FleetMetadataRow: View {
    private let key: String
    private let value: String
    private var showDivider: Bool = true

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// - Parameters:
    ///   - key: metadata key, rendered uppercased with a trailing colon.
    ///   - value: metadata value.
    ///   - showDivider: whether to render the hairline divider underneath.
    public init(_ key: String, _ value: String, showDivider: Bool = true) {
        self.key = key
        self.value = value
        self.showDivider = showDivider
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: FleetTheme.spacingSm) {
                Text(key.uppercased() + ":")
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                Text(value)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if showDivider {
                Rectangle()
                    .fill(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast))
                    .frame(height: hairlineHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key): \(value)")
    }
}

#Preview("FleetMetadataRow") {
    VStack(spacing: 0) {
        FleetMetadataRow("SEED", "0x1F98431c8")
        FleetMetadataRow("UPTIME", "17d 04:12:33")
        FleetMetadataRow("ROUTE", "@workstation/hermes-fleet-01")
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
