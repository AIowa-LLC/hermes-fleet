import SwiftUI

/// Refinement Phase 3 — Settings ▸ Theme value-picker rows (ADR-0011 W2
/// Menu anatomy: one row, immediate apply, current value trailing).

/// Curated theme picker. Replaces the retired eight-color Accent menu, five
/// of whose colors could not reach text contrast on the light canvas. A
/// persisted accent or custom palette is never rewritten; it reads "Custom"
/// until the user picks a theme.
///
/// The row keeps the `fleet.settings.accent` identifier (contract
/// continuity, as ADR-0011 did for Appearance); options are
/// `fleet.settings.theme.<id>`.
struct FleetThemeMenuRow: View {
    let controller: FleetThemeController
    @Environment(\.fleetTheme) private var theme

    private var current: FleetCuratedTheme? {
        FleetCuratedTheme.matching(active: controller.activePalette)
    }

    private var currentLabel: String { current?.label ?? "Custom" }

    var body: some View {
        Menu {
            ForEach(FleetCuratedTheme.allCases) { option in
                Button {
                    controller.apply(option.palette)
                } label: {
                    if option == current {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
                .accessibilityIdentifier("fleet.settings.theme.\(option.rawValue)")
            }
        } label: {
            HStack {
                FleetThemeSwatch(color: theme.highlight)
                Text("Theme")
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(currentLabel)
                    .foregroundStyle(theme.textSecondary)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .fleetHaptic(.selection, trigger: current)
        .accessibilityLabel("Theme, \(currentLabel)")
        .accessibilityIdentifier("fleet.settings.accent")
    }
}

/// The swatch shows the ACTIVE appearance's resolved highlight (ADR-0009:
/// Graphite renders near-black in light, white in dark), ringed so a white
/// highlight never disappears into the row.
struct FleetThemeSwatch: View {
    let color: Color
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: color)
            .accessibilityHidden(true)
    }
}

/// Alternate app icon picker. Hidden where the platform can't switch icons.
struct FleetAppIconMenuRow: View {
    let controller: FleetAppIconController
    @Environment(\.fleetTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var previewSide: CGFloat = 26

    var body: some View {
        Menu {
            ForEach(FleetAppIcon.allCases) { option in
                Button {
                    Task { await controller.select(option) }
                } label: {
                    if option == controller.current {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
                .accessibilityIdentifier("fleet.settings.app-icon.\(option.rawValue)")
            }
        } label: {
            HStack {
                Image(controller.current.previewImageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: previewSide, height: previewSide)
                    .clipShape(RoundedRectangle(cornerRadius: previewSide * 0.24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: previewSide * 0.24, style: .continuous)
                            .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
                    .accessibilityHidden(true)
                Text("App Icon")
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(controller.current.label)
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .fleetHaptic(.selection, trigger: controller.current)
        .accessibilityLabel("App Icon, \(controller.current.label)")
        .accessibilityIdentifier("fleet.settings.app-icon")
    }
}
