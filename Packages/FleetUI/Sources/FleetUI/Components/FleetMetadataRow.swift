import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pixel-hairline height (1pt on non-Retina, 0.5pt on Retina+). UIKit-only;
/// macOS host-side builds get the fixed 0.5pt (convenience only — the
/// product targets iOS).
@available(iOS 13.0, macOS 10.15, *)
private var hairlineHeight: CGFloat {
    #if canImport(UIKit)
    1 / UIScreen.main.scale
    #else
    0.5
    #endif
}

/// V1 (Nous direction) — terminal `KEY:` metadata row: muted mono key,
/// bright mono value, hairline divider underneath. The Nous voice for
/// metadata: status read like a process table (content-only styling, no
/// fake data).
public struct FleetMetadataRow: View {
    private let key: String
    private let value: String
    private var showDivider: Bool = true

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// - Parameters:
    ///   - key: metadata key, rendered `KEY:` — muted secondary mono,
    ///     automatically uppercased.
    ///   - value: metadata value — bright primary mono.
    ///   - showDivider: hairline divider underneath (default true).
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
        FleetMetadataRow("ROUTE", "@tonys-mbp/hermes-fleet-01")
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
