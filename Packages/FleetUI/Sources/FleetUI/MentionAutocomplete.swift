import SwiftUI
import Observation
import FleetCore

/// TRUE BOTS MODE slice 5 (D20) — @mention autocomplete for the room
/// composer.
///
/// Pure presentation over `MentionResolution.autocomplete`: when the composer
/// text ends in an active "@fragment", a suggestion list renders above the
/// keyboard; tapping inserts the source-qualified tag. Unknown @strings pass
/// through unchanged (the composer never rewrites resolved text), and email
/// addresses are never treated as tags (FleetCore tokenizer rules).
///
/// Inserted mention text is JUST text — delivery is gateway/room policy.
/// The UI never presents the mention as proof a bot was pinged (binding
/// mission rule).
struct MentionAutocomplete: View {
    @Environment(\.fleetTheme) private var theme
    /// Full composer draft.
    @Binding var draft: String
    /// Live fleet candidates.
    let candidates: [MentionCandidate]
    let gatewayLabel: (GatewayID) -> String

    @State private var activeQuery: String?
    @State private var rangeInDraft: Range<String.Index>?

    var body: some View {
        VStack(spacing: 0) {
            if let suggestions = currentSuggestions, !suggestions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                insert(suggestion)
                            } label: {
                                HStack(spacing: FleetTheme.spacingSm) {
                                    Image(systemName: "at")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(theme.highlight)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(suggestion.displayTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(theme.textPrimary)
                                        if let qualifier = suggestion.qualifier {
                                            Text(qualifier)
                                                .font(FleetTheme.monoCaptionFont)
                                                .foregroundStyle(theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    Text("@" + suggestion.insertText)
                                        .font(FleetTheme.monoCaptionFont)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                .padding(.horizontal, FleetTheme.spacingMd)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("fleet.mention.suggestion.\(suggestion.insertText)")
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(theme.surfaceElevated)
            }
        }
        .onAppear { track() }
        .onChange(of: draft) { _, _ in track() }
    }

    private var currentSuggestions: [MentionResolution.Suggestion]? {
        guard let query = activeQuery else { return nil }
        return MentionResolution.autocomplete(
            query: query, candidates: candidates, gatewayLabel: gatewayLabel)
    }

    /// Track the active "@fragment" at the END of the draft (the only place
    /// autocomplete applies — resolved earlier text is left untouched).
    private func track() {
        let text = draft
        guard let at = text.lastIndex(of: "@") else {
            activeQuery = nil
            rangeInDraft = nil
            return
        }
        // The @ must start a token (previous char is not a token char —
        // emails are not tags).
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            if previous.isLetter || previous.isNumber || previous == "." || previous == "_" || previous == "-" || previous == "@" {
                activeQuery = nil
                rangeInDraft = nil
                return
            }
        }
        let fragment = String(text[text.index(after: at)...])
        // Only word characters continue a mention fragment; anything else
        // closes the autocomplete session.
        if fragment.contains(where: { $0 == " " || $0 == "\n" }) {
            activeQuery = nil
            rangeInDraft = nil
            return
        }
        activeQuery = fragment
        rangeInDraft = at..<text.endIndex
    }

    private func insert(_ suggestion: MentionResolution.Suggestion) {
        guard let range = rangeInDraft else { return }
        let tag = "@" + suggestion.insertText + " "
        draft = draft.replacingCharacters(in: range, with: tag)
        activeQuery = nil
        rangeInDraft = nil
    }
}
