import SwiftUI
import FleetCore

/// Compact action toolbar under a completed assistant reply.
///
/// The component is shared by direct conversations and bridged-room
/// transcripts. The owner supplies only actions that are safe for that surface;
/// unavailable actions remain visibly disabled in More rather than pretending
/// to work or silently disappearing.
struct AssistantReplyFooter: View {
    @Environment(\.fleetTheme) private var theme

    /// The literal visible reply text used by copy, share, speech, and search.
    let text: String

    /// Existing Tapback seam. Nil means this surface has no reaction wire path.
    var react: ((_ emoji: String) -> Void)?
    var ownReaction: String?

    /// More-menu actions. Nil actions render disabled, honest menu entries.
    var onBranch: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onSearchWeb: (() -> Void)? = nil
    var isSearchInFlight: Bool = false

    /// Existing shared AVSpeechSynthesizer seam.
    var readAloud: (() -> Void)?
    var stopReading: (() -> Void)?
    var isReading: Bool = false

    /// Stable per-row accessibility namespace.
    var idNamespace: String

    /// Every SF Symbol this footer renders. A nonexistent name renders a
    /// SILENT blank glyph that still passes every AX/tap contract (dogfood
    /// build 78 shipped an invisible-but-working copy button because
    /// "doc.on.document" does not exist), so this catalog exists for the
    /// resolution test — keep it in sync with the literals below.
    static let glyphNames: [String] = [
        "doc.on.doc", "hand.thumbsup", "hand.thumbsdown",
        "square.and.arrow.up", "ellipsis",
        "arrow.trianglehead.branch", "speaker.wave.2", "stop.fill",
        "arrow.clockwise", "progress.indicator", "globe",
    ]

    @State private var showingCopiedConfirmation = false

    var body: some View {
        HStack(spacing: 2) {
            copyButton
            if let react {
                thumbsButton(emoji: "👍", label: "Like reply", symbol: "hand.thumbsup", react: react)
                thumbsButton(emoji: "👎", label: "Dislike reply", symbol: "hand.thumbsdown", react: react)
            }
            shareButton
            moreMenu
            if showingCopiedConfirmation {
                Text("Copied")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .transition(.opacity)
                    .accessibilityIdentifier("\(idNamespace).copied")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply actions")
        .accessibilityIdentifier("\(idNamespace).footer")
    }

    // MARK: - Copy

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.easeIn(duration: 0.15)) { showingCopiedConfirmation = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.25)) { showingCopiedConfirmation = false }
            }
        } label: {
            footerGlyph("doc.on.doc", active: false)
        }
        .accessibilityLabel("Copy reply")
        .accessibilityIdentifier("\(idNamespace).copy")
    }

    // MARK: - Thumbs

    private func thumbsButton(
        emoji: String,
        label: String,
        symbol: String,
        react: @escaping (String) -> Void
    ) -> some View {
        Button {
            react(emoji)
        } label: {
            footerGlyph(symbol, active: ownReaction == emoji)
        }
        .accessibilityLabel(ownReaction == emoji ? "\(label), active" : label)
        .accessibilityIdentifier("\(idNamespace).react.\(emoji)")
    }

    // MARK: - Share

    private var shareButton: some View {
        ShareLink(item: text, preview: SharePreview("Assistant reply")) {
            footerGlyph("square.and.arrow.up", active: false)
        }
        .accessibilityLabel("Share reply")
        .accessibilityIdentifier("\(idNamespace).share")
    }

    // MARK: - More

    private var moreMenu: some View {
        Menu {
            Button {
                onBranch?()
            } label: {
                Label("Branch in New Chat", systemImage: "arrow.trianglehead.branch")
            }
            .disabled(onBranch == nil)
            .accessibilityHint(onBranch == nil ? "Branching this reply is unavailable" : "Starts a new chat with history through this reply")
            .accessibilityIdentifier("\(idNamespace).more.branch")

            Button {
                if isReading { stopReading?() } else { readAloud?() }
            } label: {
                Label(
                    isReading ? "Stop Reading" : "Read Aloud",
                    systemImage: isReading ? "stop.fill" : "speaker.wave.2"
                )
            }
            .disabled(isReading ? stopReading == nil : readAloud == nil)
            .accessibilityHint((isReading ? stopReading : readAloud) == nil ? "Read aloud is unavailable" : "Speaks this reply")
            .accessibilityIdentifier("\(idNamespace).more.read-aloud")

            Button {
                onRetry?()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(onRetry == nil)
            .accessibilityHint(onRetry == nil ? "Retry is available only for the latest completed reply" : "Regenerates this reply")
            .accessibilityIdentifier("\(idNamespace).more.retry")

            Button {
                onSearchWeb?()
            } label: {
                if isSearchInFlight {
                    Label("Searching the Web…", systemImage: "progress.indicator")
                } else {
                    Label("Search the Web", systemImage: "globe")
                }
            }
            .disabled(onSearchWeb == nil || isSearchInFlight)
            .accessibilityHint(onSearchWeb == nil ? "Web search is unavailable on this gateway" : "Searches using this reply as context")
            .accessibilityIdentifier("\(idNamespace).more.search-web")
        } label: {
            footerGlyph("ellipsis", active: isReading || isSearchInFlight)
        }
        .accessibilityLabel(isReading ? "More actions, reading aloud" : "More actions")
        .accessibilityIdentifier("\(idNamespace).more")
    }

    // MARK: - Glyph

    /// The label owns the ≥44×44 target; this is an in-page control rather
    /// than a navigation-bar item, so Dynamic Type keeps the hit area intact.
    private func footerGlyph(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .font(.footnote)
            .imageScale(.small)
            .foregroundStyle(active ? theme.highlight : theme.textSecondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
