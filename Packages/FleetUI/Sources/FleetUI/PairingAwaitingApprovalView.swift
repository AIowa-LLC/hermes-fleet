import SwiftUI
import UIKit
import FleetCore

/// The waiting screen: the code the phone shows and the owner approves. Presentation only;
/// polling is owned by `PairingCoordinator`.
struct PairingAwaitingApprovalView: View {
    @Environment(\.fleetTheme) private var theme
    @ScaledMetric(relativeTo: .largeTitle) private var codeSize: CGFloat = 52
    let code: String
    let expiresAt: Date
    let gatewayName: String?
    let host: String?
    let onCancel: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Text("Waiting for approval")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("fleet.pairing.approval.title")
                if let target = gatewayName ?? host {
                    Text(target)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.pairing.approval.server")
                }
            }

            FleetCard {
                VStack(spacing: FleetTheme.spacingMd) {
                    Text(PairingMatchCode.spaced(code))
                        .font(.system(size: codeSize, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .kerning(2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Match code \(PairingMatchCode.spoken(code))")
                        .accessibilityIdentifier("fleet.pairing.approval.code")
                    Text("Make sure Hermes shows the same code when you approve.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("Send this to Hermes:")
                    .font(FleetTheme.sectionHeaderFont)
                    .foregroundStyle(theme.textPrimary)
                Text(PairingMatchCode.approveCommand(code))
                    .font(.body.monospaced())
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.pairing.approval.command")
                Button {
                    UIPasteboard.general.string = PairingMatchCode.approveCommand(code)
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.pairing.approval.copy")
                Text("or answer y in the terminal running `hermes fleet pair`")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.pairing.approval.terminal")
            }

            HStack(spacing: FleetTheme.spacingSm) {
                ProgressView()
                    .tint(theme.highlight)
                    .accessibilityHidden(true)
                // The visible countdown ticks every second; VoiceOver gets a calm relative phrase instead.
                Text(timerInterval: Date()...max(expiresAt, Date()), countsDown: true, showsHours: false)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                Text("Expires \(expiresAt, style: .relative)")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.pairing.approval.expiry")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fleet.pairing.approval.countdown")

            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("fleet.pairing.approval.cancel")
        }
    }
}

/// Denied / expired: the request is over; the way forward is a fresh link.
struct PairingEndedView: View {
    enum Kind { case denied, expired }
    @Environment(\.fleetTheme) private var theme
    let kind: Kind
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    Label(title, systemImage: kind == .denied ? "xmark.shield" : "clock.badge.exclamationmark")
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(FleetTheme.statusNeedsIntervention)
                        .accessibilityIdentifier("fleet.pairing.ended.title")
                    Text(message)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.pairing.ended.message")
                    Text("Get a new link: send `/fleet pair` to Hermes in a private chat, or run `hermes fleet pair` on your computer.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.pairing.ended.guidance")
                }
            }
            Button(action: onDone) {
                Text("Back")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .foregroundStyle(theme.onHighlight)
            .accessibilityIdentifier(kind == .denied ? "fleet.pairing.denied.done" : "fleet.pairing.expired.done")
        }
        .accessibilityIdentifier(kind == .denied ? "fleet.pairing.denied" : "fleet.pairing.expired")
    }

    private var title: String {
        kind == .denied ? "The request was denied" : "The request expired"
    }

    private var message: String {
        switch kind {
        case .denied:
            return "The owner declined this request, so nothing was added to this phone."
        case .expired:
            return "Nobody approved the code in time, so nothing was added to this phone."
        }
    }
}
