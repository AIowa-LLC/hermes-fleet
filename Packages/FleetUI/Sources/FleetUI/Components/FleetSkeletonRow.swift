import SwiftUI

/// Initial-load placeholder shaped like a `FleetListRow` (avatar circle plus
/// two text lines). Used ONLY for the cold "nothing loaded yet" state; in-place
/// refresh spinners keep their `ProgressView`.
///
/// The placeholder text is `.redacted(reason: .placeholder)`, and the row
/// shimmers gently. The shimmer is disabled under Reduce Motion (static).
public struct FleetSkeletonRow: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    public init() {}

    public var body: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Circle()
                .fill(theme.border)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                Text("Loading conversation title")
                    .font(.body.weight(.semibold))
                Text("gateway · 00m")
                    .font(FleetTheme.monoCaptionFont)
            }
            .redacted(reason: .placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.vertical, FleetTheme.spacingSm)
        .frame(minHeight: 44, alignment: .leading)
        .opacity(reduceMotion ? 1 : (dimmed ? 0.5 : 1))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
            value: dimmed
        )
        .onAppear { if !reduceMotion { dimmed = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// A block of `count` skeleton rows presented as ONE accessibility element
/// (label "Loading") carrying `identifier`, so the placeholder replaces the old
/// spinner's identity without exposing per-row children to VoiceOver.
public struct FleetSkeletonList: View {
    private let count: Int
    private let identifier: String

    public init(count: Int = 5, identifier: String) {
        self.count = max(1, min(count, 6))
        self.identifier = identifier
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                FleetSkeletonRow()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier(identifier)
    }
}

#Preview("FleetSkeletonList") {
    List {
        FleetSkeletonList(identifier: "preview.skeleton")
    }
}
