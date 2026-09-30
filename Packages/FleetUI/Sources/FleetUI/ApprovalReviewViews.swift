import SwiftUI
import FleetCore

// P0.2a — shared approval components: the origin header, the collapsed
// command preview, the untrusted-detail block and the full-command review
// sheet. Used by the conversation `ApprovalBanner` and by the Home Live Ops
// approval row so both apply the same header and review rules. Cards stay
// opaque; glass styling is a separate issue.

// MARK: - Origin header

/// Gateway · bot · working folder · session, always four lines, unknown
/// values shown as "unknown". Read by VoiceOver as one phrase.
struct ApprovalOriginHeader: View {
    @Environment(\.fleetTheme) private var theme
    let origin: ApprovalOrigin

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Gateway", origin.gatewayLabel, id: "gateway")
            row("Bot", origin.botLabel, id: "bot")
            row("Folder", origin.cwd, id: "cwd", mono: true)
            row("Session", origin.sessionLabel, id: "session")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(origin.accessibilityDescription)
        .accessibilityIdentifier("approval.origin")
    }

    private func row(_ label: String, _ value: String, id: String, mono: Bool = false) -> some View {
        // One concatenated Text per row wraps naturally at any Dynamic Type
        // size instead of forcing a fixed label column.
        (Text(label + "  ")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
         + Text(value)
            .font(mono ? FleetTheme.monoCaptionFont : .caption)
            .foregroundStyle(theme.textPrimary))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("approval.origin.\(id)")
    }
}

// MARK: - Collapsed preview

/// The inline command preview: a bounded head with an explicit, visible
/// elision marker and a "Review full command" action. There is no middle
/// truncation anywhere.
struct ApprovalCommandPreviewView: View {
    @Environment(\.fleetTheme) private var theme
    let command: String
    let onReview: () -> Void

    private var preview: ApprovalCommandPreview { ApprovalCommandPreview(command: command) }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.visibleText)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("approval.banner.command")
                if let marker = preview.elisionMarker {
                    Text(marker)
                        .font(FleetTheme.monoCaptionFont.weight(.semibold))
                        .foregroundStyle(FleetTheme.statusNeedsIntervention)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("approval.banner.elision")
                }
            }
            .padding(.horizontal, FleetTheme.spacingSm)
            .padding(.vertical, 6)
            .background(
                theme.background,
                in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                    .strokeBorder(FleetTheme.statusNeedsIntervention.opacity(0.4), lineWidth: 1)
            )

            if preview.isElided {
                Button(action: onReview) {
                    Label("Review full command", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.fleetPressable)
                .foregroundStyle(theme.highlight)
                .accessibilityIdentifier("approval.review.open")
                .accessibilityHint("Opens the whole command. Approve stays off until you have reviewed it.")
            }
        }
    }
}

// MARK: - Untrusted detail

/// Gateway-supplied `detail` text. It is agent-authored, so it sits inside a
/// labelled block and can never read as app copy. Long text is expandable,
/// never silently clipped.
struct ApprovalUntrustedDetail: View {
    @Environment(\.fleetTheme) private var theme
    let detail: String
    /// Start expanded (the review sheet shows everything).
    var startsExpanded = false
    @State private var expanded = false

    private var isLong: Bool {
        detail.count > 120 || detail.split(whereSeparator: \.isNewline).count > 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Reason given by gateway (untrusted text)", systemImage: "quote.bubble")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit((expanded || startsExpanded) ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("approval.detail.text")
            if isLong && !startsExpanded {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("approval.detail.toggle")
            }
        }
        .padding(FleetTheme.spacingSm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.detail.untrusted")
    }
}

// MARK: - Review sheet

/// Full-command review: the whole redacted command, monospaced, selectable
/// and scrollable with a wrap toggle. Finishing the review (reaching the end
/// while wrapped, or tapping "I reviewed the full command") calls
/// `onReviewed`; closing the sheet any other way does not.
struct ApprovalReviewSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let origin: ApprovalOrigin
    let command: String
    let detail: String?
    let isReviewed: Bool
    let onReviewed: () -> Void

    @State private var wraps = true

    private var lineCount: Int { ApprovalCommandPreview.lines(of: command).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    ApprovalOriginHeader(origin: origin)

                    HStack(alignment: .firstTextBaseline) {
                        Text("\(lineCount) \(lineCount == 1 ? "line" : "lines") · \(command.count) characters")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityIdentifier("approval.review.count")
                        Spacer(minLength: FleetTheme.spacingSm)
                    }
                    Toggle("Wrap lines", isOn: $wraps)
                        .font(.subheadline)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("approval.review.wrap")

                    commandView

                    if let detail, !detail.isEmpty {
                        ApprovalUntrustedDetail(detail: detail, startsExpanded: true)
                    }
                }
                .padding(FleetTheme.spacingLg)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let overflows = geometry.contentSize.height > geometry.containerSize.height + 1
                let atEnd = geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 8
                return overflows && atEnd
            } action: { _, reachedEnd in
                // Reaching the end counts only while lines wrap: with wrap
                // off, text can still extend past the right edge.
                if reachedEnd && wraps && !isReviewed { onReviewed() }
            }
            .background(theme.background)
            .navigationTitle("Full command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("approval.review.close")
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("approval.review.sheet")
    }

    @ViewBuilder
    private var commandView: some View {
        let text = Text(command)
            .font(FleetTheme.monoFont)
            .foregroundStyle(theme.textPrimary)
            .textSelection(.enabled)
            .padding(FleetTheme.spacingSm)
        Group {
            if wraps {
                text.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    text.fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .strokeBorder(FleetTheme.statusNeedsIntervention.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("approval.review.command")
    }

    private var confirmBar: some View {
        VStack(spacing: 4) {
            if isReviewed {
                Label("Reviewed", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FleetTheme.statusOnline)
                    .accessibilityIdentifier("approval.review.reviewed")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("approval.review.done")
            } else {
                Button {
                    onReviewed()
                    dismiss()
                } label: {
                    Text("I reviewed the full command")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("approval.review.confirm")
            }
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
    }
}
