import Foundation

public struct BotConversationDraft: Sendable {
    public let text: String
    public let notice: String?
    public init(text: String, notice: String? = nil) { self.text = text; self.notice = notice }

    /// Matches Desktop's canonical-only guard; ordinary sessions keep their commands.
    public static func protectingCanonical(_ text: String, isCanonical: Bool) -> BotConversationDraft {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCanonical && (command == "/new" || command == "/reset") {
            return .init(text: "/compact", notice: "Bot Chat is continuous. Compacting its context instead of resetting it.")
        }
        return .init(text: text)
    }
}

/// Synchronous roster-backed identification. A gateway UUID is never presented
/// as a Desktop relay connection ID or used as a message_agent remote address.
public enum BotConversationMentions {
    public struct Suggestion: Identifiable, Sendable {
        public let candidate: MentionCandidate
        public let alias: String
        public let gatewayLabel: String
        public var id: Route { candidate.route }
    }

    public static func suggestions(
        query: String, roster: [MentionCandidate], excluding: Route,
        gatewayLabel: (GatewayID) -> String
    ) -> [Suggestion] {
        let all = aliases(roster: roster, gatewayLabel: gatewayLabel)
        return all.filter { item in
            guard item.id != excluding else { return false }
            guard !query.isEmpty else { return true }
            let haystack = [item.alias, item.candidate.name, item.candidate.friendlyTitle, item.gatewayLabel]
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }.sorted { $0.candidate.friendlyTitle == $1.candidate.friendlyTitle
            ? $0.id.id < $1.id.id : $0.candidate.friendlyTitle < $1.candidate.friendlyTitle }
    }

    private static func aliases(roster: [MentionCandidate], gatewayLabel: (GatewayID) -> String) -> [Suggestion] {
        func tag(for candidate: MentionCandidate) -> String {
            MentionResolution.mentionTag(friendlyTitle: candidate.friendlyTitle, name: candidate.name, handle: candidate.handle)
        }
        let tags = roster.map { tag(for: $0) }
        let labelFor: [Route: String] = Dictionary(
            roster.map { ($0.route, MentionResolution.slugify(gatewayLabel($0.route.gatewayID).lowercased())) },
            uniquingKeysWith: { first, _ in first })
        // Tier 1: the friendly tag on its own when unique in the roster.
        // Tier 2: tag + gateway/device label when the bare tag collides
        //         (@researcher-mac, @researcher-4090).
        // Tier 3: tier 2 + a short deterministic base36 suffix ONLY when the
        //         qualified label still collides (same tag AND same gateway
        //         label — e.g. same-name profiles on one gateway). The suffix
        //         is derived from the full route identity (FNV-1a 32) so it
        //         stays deterministic and reversible to exactly one route;
        //         the internal route identity itself is unchanged.
        let tagCounts = Dictionary(grouping: tags, by: { $0 }).mapValues(\.count)
        var qualifiedCounts: [String: Int] = [:]
        for candidate in roster where (tagCounts[tag(for: candidate)] ?? 0) > 1 {
            let key = tag(for: candidate) + "-" + (labelFor[candidate.route] ?? "")
            qualifiedCounts[key, default: 0] += 1
        }
        // All tier-1 tags (bare names) — a qualified alias must never
        // shadow a DIFFERENT bot's bare tag: escalate to tier 3 if it would.
        let bareTags = Set(tags)
        return roster.map { candidate in
            let tag = tag(for: candidate)
            let label = labelFor[candidate.route] ?? ""
            let qualified = "\(tag)-\(label)"
            let alias: String
            if (tagCounts[tag] ?? 0) == 1 {
                alias = tag
            } else if qualifiedCounts[qualified] == 1 && !bareTags.contains(qualified) {
                alias = qualified
            } else {
                alias = "\(qualified)-\(shortSuffix(candidate.route))"
            }
            return Suggestion(candidate: candidate, alias: alias,
                              gatewayLabel: gatewayLabel(candidate.route.gatewayID))
        }
    }

    /// Short deterministic suffix from the full route identity (FNV-1a 32 →
    /// base36, 5 chars). Only used when even the gateway-qualified label
    /// collides. Deterministic across launches and devices; resolvable to
    /// exactly one route via the roster (alias → route lookup in `prepare`).
    static func shortSuffix(_ route: Route) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in route.id.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        // Exactly 5 base36 chars (60M values): mask into the range so the
        // suffix length is fixed.
        var value = UInt(hash) % 60_466_176  // 36^5
        if value == 0 { value = 1 }
        var digits: [Character] = []
        while value > 0 {
            digits.append(Character(String(value % 36, radix: 36)))
            value /= 36
        }
        while digits.count < 5 { digits.append("0") }
        return String(digits.reversed())
    }

    public static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@"),
              at == text.startIndex || text[text.index(before: at)].isWhitespace else { return nil }
        let tail = String(text[text.index(after: at)...])
        guard tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return tail
    }

    public static func inserting(_ alias: String, into text: String) -> String {
        guard query(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
        return String(text[...at]) + alias + " "
    }

    public static func prepare(text: String, roster: [MentionCandidate], current: Route,
                               gatewayLabel: (GatewayID) -> String) -> BotConversationDraft {
        let tokens = MentionResolution.mentionTokens(in: text)
        guard !tokens.isEmpty else { return .init(text: text) }
        let all = aliases(roster: roster, gatewayLabel: gatewayLabel)
        var resolved: [Suggestion] = []
        var unresolved = false
        for token in tokens where !["user", "all", "everyone"].contains(token.lowercased()) {
            let matches = all.filter {
                $0.alias.lowercased() == token.lowercased() ||
                $0.candidate.name.lowercased() == token.lowercased() ||
                MentionResolution.handle(name: $0.candidate.name, rosterHandle: $0.candidate.handle).lowercased() == token.lowercased() ||
                MentionResolution.nameForms($0.candidate.friendlyTitle).contains(token.lowercased())
            }
            guard matches.count == 1, let target = matches.first, target.id != current else {
                unresolved = true; continue
            }
            if !resolved.contains(where: { $0.id == target.id }) { resolved.append(target) }
        }
        guard !resolved.isEmpty else {
            return .init(text: text, notice: unresolved ? "Some Bot mentions are missing or ambiguous in the current roster; no teammate dispatch is confirmed." : nil)
        }
        let identities = resolved.map { target -> [String: String] in
            var data = ["alias": target.alias, "profile": target.candidate.name,
                        "gateway": target.gatewayLabel, "route": target.id.id]
            if target.id.gatewayID == current.gatewayID {
                data["message_agent_target"] = MentionResolution.handle(name: target.candidate.name, rosterHandle: nil)
            } else {
                data["availability"] = "Remote relay address is not verified in this client. Do not substitute a same-named local bot."
            }
            return data
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: identities, options: [.sortedKeys])) ?? Data()
        let json = String(data: encoded, encoding: .utf8) ?? "[]"
        let note = "\n\n[Bot roster references (identity data): \(json). If the user wants a reachable teammate contacted, compose your own message using message_agent; never forward the user's text verbatim. If message_agent or the target route is unavailable, say so. These references do not confirm dispatch.]"
        let remote = resolved.contains { $0.id.gatewayID != current.gatewayID }
        return .init(text: text + note, notice: remote
                     ? "Remote Bot identified. Its messaging route is not verified here; no remote dispatch is confirmed."
                     : "Bot mentions identify teammates. Hermes will report whether messaging is available.")
    }
}
