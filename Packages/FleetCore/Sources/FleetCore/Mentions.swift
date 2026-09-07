import Foundation

/// TRUE BOTS MODE slice 5 (D20) — fleet mention domain: autocomplete over the
/// live fleet roster, mention-token parsing, and source-qualified resolution.
///
/// Clean-room Swift port of the ACTUAL teammate workflow at upstream 08b140d
/// (NOT docs):
/// - `mentionNameForms` — apps/desktop/src/plugins/hermes-bots/data.ts:971-986:
///   friendly names reduce to the mention charset TWO ways — slugified
///   ("Research Buddy" → research-buddy, the form autocomplete inserts) and
///   collapsed (researchbuddy); reserved tokens are dropped so a bot renamed
///   "Hermes" can never hijack the primary profile's @hermes alias.
/// - `botHandle` — data.ts:953-962: prefer the roster handle; the primary
///   profile's callable alias is "hermes" (the word "default" never surfaces).
/// - `botMentionTag` — data.ts:1004-1015: the tag autocomplete inserts = first
///   friendly-name form, else the profile @handle.
/// - `parseGroupChatMentions` — group-rounds.ts:45-90: regex
///   `@([a-z0-9][a-z0-9._-]*)` case-insensitive; @everyone/@all set the
///   everyone flag; @user is skipped; resolution matches handle/name forms
///   with separators collapsed; UNRESOLVED tokens pass through unchanged
///   (they are left in the text and never fabricated into a delivery).
/// - `groupMemberKey` — group-membership.ts: bare name for local members,
///   `connectionId::name` for remote/source-scoped members (upstream test:
///   `mac-mini::dixie`). This is the source-qualified identity a duplicate
///   name resolves to.
/// - Emails are NOT tags: the mention charset regex stops at `@`-token
///   boundaries that contain `@` in the local part... concretely, an email
///   like `ops@example.com` never yields the tag `example.com` because the
///   regex scans tokens that START at `@` — `ops@` is not a token start.
/// - Duplicate disambiguation: unique bare names match; duplicate names
///   require the source-qualified handle (data.ts resolveRosterMentions
///   docstring; @name-device handle rule).

// MARK: - Mention identity

/// One mentionable fleet member (bot) with its source-qualified identity.
public struct MentionCandidate: Hashable, Sendable, Identifiable {
    /// Canonical route identity (never the display name).
    public let route: Route
    /// Friendly title (BotMeta.title → display_name → slug precedence).
    public let friendlyTitle: String
    /// Roster handle when present (the precomputed disambiguated form).
    public let handle: String?

    public init(route: Route, friendlyTitle: String, handle: String? = nil) {
        self.route = route
        self.friendlyTitle = friendlyTitle
        self.handle = handle
    }

    public var id: String { route.id }

    /// The profile slug.
    public var name: String { route.profileSlug.rawValue }

    /// Source qualifier: the gateway's roster key form `gateway::slug` —
    /// distinct for the same slug on two gateways (D18/D20 identity pillar).
    public func sourceQualifiedKey(gatewayLabel: String) -> String {
        "\(gatewayLabel)::\(name)"
    }
}

/// Mention form derivation + resolution (pure; no SwiftUI, no networking).
public enum MentionResolution {

    public static let reservedForms: Set<String> = [
        "all", "everyone", "user", "default", "hermes",
    ]

    /// Taggable @-forms from a friendly name (data.ts mentionNameForms):
    /// slug + collapsed, filtered to the mention charset and reserved words.
    public static func nameForms(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }
        let slug = slugify(name)
        let collapsed = collapse(name)
        var seen = Set<String>()
        var forms: [String] = []
        for form in [slug, collapsed] where !form.isEmpty {
            if !seen.contains(form),
               isValidMentionForm(form),
               !reservedForms.contains(form) {
                seen.insert(form)
                forms.append(form)
            }
        }
        return forms
    }

    /// `botHandle` (data.ts:953-962): prefer the roster handle; the primary
    /// profile's callable alias is "hermes" so "default" never surfaces.
    public static func handle(name: String, rosterHandle: String?) -> String {
        if let rosterHandle, rosterHandle != name {
            return rosterHandle
        }
        return name.lowercased() == "default" ? "hermes" : name
    }

    /// `botMentionTag` (data.ts:1004-1015): the tag autocomplete inserts —
    /// the first friendly-name form, else the profile handle.
    public static func mentionTag(
        friendlyTitle: String, name: String, handle: String?
    ) -> String {
        for form in nameForms(friendlyTitle) {
            return form
        }
        return self.handle(name: name, rosterHandle: handle)
    }

    /// Slugify to the mention charset: keep `[a-z0-9_-]`, collapse any other
    /// run into a single `-`, trim leading/trailing `-`.
    static func slugify(_ value: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in value.unicodeScalars {
            if isMentionScalar(scalar) {
                if pendingSeparator && !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(Character(scalar))
            } else {
                pendingSeparator = true
            }
        }
        return out
    }

    /// Collapse separators entirely ("research buddy" → "researchbuddy").
    static func collapse(_ value: String) -> String {
        String(value.unicodeScalars.filter { isMentionScalar($0) }.map(Character.init))
    }

    static func isMentionScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)      // 0-9
            || (scalar.value >= 97 && scalar.value <= 122) // a-z
            || scalar == "_" || scalar == "-"
    }

    /// Mention-form charset check `/^[a-z0-9][a-z0-9_-]*$/`.
    public static func isValidMentionForm(_ form: String) -> Bool {
        guard let first = form.unicodeScalars.first else { return false }
        guard isAlnum(first) else { return false }
        return form.unicodeScalars.allSatisfy { isMentionScalar($0) }
    }

    static func isAlnum(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
    }

    // MARK: - Token parsing (group-rounds.ts:75-90)

    /// All `@token` candidates in text (regex `@([a-z0-9][a-z0-9._-]*)`,
    /// case-insensitive). An `@` preceded by a token character is INSIDE an
    /// email address (`ops@example.com`) and never starts a tag (D20:
    /// emails are not tags). Unresolved tokens pass through unchanged — the
    /// caller never rewrites the user's text.
    public static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "@",
               i + 1 < chars.count, isTokenStart(chars[i + 1]),
               i == 0 || !isTokenChar(chars[i - 1]) {
                var j = i + 1
                var token = ""
                while j < chars.count, isTokenChar(chars[j]) {
                    token.append(chars[j])
                    j += 1
                }
                if !token.isEmpty { tokens.append(token) }
                i = j
            } else {
                i += 1
            }
        }
        return tokens
    }

    static func isTokenStart(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    static func isTokenChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "." || c == "_" || c == "-"
    }

    /// True when the token is an email local-part continuation — i.e. the "@"
    /// we are looking at sits INSIDE an email address (`ops@example.com`):
    /// the character BEFORE the `@` is a token character, so this @ does not
    /// START a mention token. Emails are never tags (D20).
    public static func isEmailToken(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        let previous = text[text.index(before: index)]
        return isTokenChar(previous)
    }

    /// Mention parse result: resolved source-qualified keys + everyone flag +
    /// unknown tokens preserved verbatim (never rewritten, never delivered).
    public struct ParsedMentions: Hashable, Sendable {
        /// Source-qualified member keys (`gateway::slug` or bare slug).
        public let mentioned: [String]
        public let everyone: Bool
        /// @tokens that resolved to nothing — preserved unchanged.
        public let unknownTokens: [String]

        public init(mentioned: [String], everyone: Bool, unknownTokens: [String]) {
            self.mentioned = mentioned
            self.everyone = everyone
            self.unknownTokens = unknownTokens
        }
    }

    /// Parse @mentions in text against candidates
    /// (group-rounds.ts:45-90 semantics, fleet-roster shaped).
    ///
    /// Duplicate rule: a bare form claimed by 2+ candidates does NOT match —
    /// only the source-qualified handle (`gateway::slug` form or the roster's
    /// disambiguated handle) resolves. Unique bare names match directly.
    public static func parse(
        text: String, candidates: [MentionCandidate],
        gatewayLabel: (GatewayID) -> String
    ) -> ParsedMentions {
        var formMap: [String: MentionCandidate?] = [:]
        var qualifiedMap: [String: MentionCandidate] = [:]

        for candidate in candidates {
            let label = gatewayLabel(candidate.route.gatewayID)
            let qualified = candidate.sourceQualifiedKey(gatewayLabel: label)
            qualifiedMap[qualified.lowercased()] = candidate

            let bareHandle = handle(name: candidate.name, rosterHandle: candidate.handle)
            var forms = Set<String>()
            forms.insert(candidate.name.lowercased())
            forms.insert(collapse(candidate.name.lowercased()))
            if let handle = candidate.handle {
                forms.insert(handle.lowercased())
                forms.insert(collapse(handle.lowercased()))
            }
            // Renamed bots answer to friendly names too (slug + collapsed).
            for form in nameForms(candidate.friendlyTitle) {
                forms.insert(form)
            }
            for form in forms where !form.isEmpty {
                // Bare-form duplicate collision: poison the entry (nil) so it
                // NEVER matches by bare name (upstream: unique bare names
                // match; duplicates require the qualified handle).
                if let existing = formMap[form] {
                    switch existing {
                    case .some(let held) where held.route == candidate.route:
                        break
                    case .some:
                        formMap[form] = .some(nil)
                    case .none:
                        break
                    }
                } else {
                    formMap[form] = .some(candidate)
                }
            }
        }

        var mentioned: [String] = []
        var everyone = false
        var unknown: [String] = []
        var seen = Set<String>()

        for token in mentionTokens(in: text) {
            let lowered = token.lowercased()
            if lowered == "everyone" || lowered == "all" {
                everyone = true
                continue
            }
            if lowered == "user" {
                continue
            }
            var resolved: String?
            if let candidate = formMap[lowered], let c = candidate {
                resolved = c.sourceQualifiedKey(
                    gatewayLabel: gatewayLabel(c.route.gatewayID))
            }
            if resolved == nil, let candidate = qualifiedMap[lowered] {
                resolved = candidate.sourceQualifiedKey(
                    gatewayLabel: gatewayLabel(candidate.route.gatewayID))
            }
            if resolved == nil, let candidate = formMap[collapse(lowered)] {
                if let c = candidate {
                    resolved = c.sourceQualifiedKey(
                        gatewayLabel: gatewayLabel(c.route.gatewayID))
                }
            }
            if let resolved, !seen.contains(resolved) {
                seen.insert(resolved)
                mentioned.append(resolved)
            } else if resolved == nil {
                unknown.append(token)
            }
        }

        return ParsedMentions(mentioned: mentioned, everyone: everyone, unknownTokens: unknown)
    }

    // MARK: - Autocomplete (D20 UI support)

    /// Autocomplete suggestion for one candidate.
    public struct Suggestion: Hashable, Sendable, Identifiable {
        public let candidate: MentionCandidate
        /// The exact text inserted at the @-cursor (source-qualified when the
        /// bare form is ambiguous).
        public let insertText: String
        public let displayTitle: String
        public let qualifier: String?

        public var id: String { candidate.id }

        public init(
            candidate: MentionCandidate, insertText: String,
            displayTitle: String, qualifier: String?
        ) {
            self.candidate = candidate
            self.insertText = insertText
            self.displayTitle = displayTitle
            self.qualifier = qualifier
        }
    }

    /// Autocomplete over the live fleet roster for a query fragment typed
    /// after "@". Matches mention forms + source-qualified handles; the
    /// insert text is source-qualified when the bare tag is ambiguous
    /// (duplicate names across gateways — @name-gateway disambiguation).
    public static func autocomplete(
        query: String, candidates: [MentionCandidate],
        gatewayLabel: (GatewayID) -> String
    ) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            // Empty query: ranked default list (title first, then route id).
            return candidates.map { candidate in
                suggestion(candidate, bareAmbiguous: false, gatewayLabel: gatewayLabel)
            }
        }
        var out: [Suggestion] = []
        var seen = Set<String>()
        for candidate in candidates {
            let label = gatewayLabel(candidate.route.gatewayID)
            let qualified = candidate.sourceQualifiedKey(gatewayLabel: label)
            let bareTag = mentionTag(
                friendlyTitle: candidate.friendlyTitle,
                name: candidate.name, handle: candidate.handle)
            let bareAmbiguous = candidates.filter {
                mentionTag(friendlyTitle: $0.friendlyTitle, name: $0.name, handle: $0.handle)
                    .lowercased() == bareTag.lowercased()
            }.count > 1
            let haystack = [
                bareTag, candidate.name, candidate.friendlyTitle, qualified, label,
            ].joined(separator: " ").lowercased()
            if haystack.contains(q), !seen.contains(candidate.id) {
                seen.insert(candidate.id)
                out.append(suggestion(
                    candidate, bareAmbiguous: bareAmbiguous,
                    gatewayLabel: gatewayLabel))
            }
        }
        return out
    }

    static func suggestion(
        _ candidate: MentionCandidate, bareAmbiguous: Bool,
        gatewayLabel: (GatewayID) -> String
    ) -> Suggestion {
        let label = gatewayLabel(candidate.route.gatewayID)
        let bareTag = mentionTag(
            friendlyTitle: candidate.friendlyTitle,
            name: candidate.name, handle: candidate.handle)
        // Duplicate disambiguation: @name-gateway (upstream @name-device).
        let insert = bareAmbiguous
            ? "\(bareTag)-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
            : bareTag
        return Suggestion(
            candidate: candidate,
            insertText: insert,
            displayTitle: candidate.friendlyTitle.isEmpty ? candidate.name : candidate.friendlyTitle,
            qualifier: bareAmbiguous ? label : nil)
    }
}

// MARK: - Fleet roster → mention candidates

/// Bridge from the live fleet roster snapshot to mention candidates.
public enum FleetMentionCandidates {
    /// Candidates from the full fleet roster (EVERY gateway — mentions reach
    /// across the fleet; hidden bots remain mentionable per design §3.4).
    public static func from(
        botsByGateway: [GatewayID: [FleetBot]],
        gatewayLabel: (GatewayID) -> String
    ) -> [MentionCandidate] {
        var out: [MentionCandidate] = []
        for (gatewayID, bots) in botsByGateway.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for bot in bots {
                out.append(MentionCandidate(
                    route: bot.route,
                    friendlyTitle: BotRosterPresentation.displayTitle(for: bot),
                    handle: bot.uiMeta?["handle"]?.stringValue))
            }
        }
        return out
    }
}
