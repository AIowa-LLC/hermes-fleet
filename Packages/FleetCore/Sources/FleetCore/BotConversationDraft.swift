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
        return all.filter {
            $0.id != excluding && (query.isEmpty ||
                "\($0.alias) \($0.candidate.name) \($0.candidate.friendlyTitle) \($0.gatewayLabel)"
                    .localizedCaseInsensitiveContains(query))
        }.sorted { $0.candidate.friendlyTitle == $1.candidate.friendlyTitle
            ? $0.id.id < $1.id.id : $0.candidate.friendlyTitle < $1.candidate.friendlyTitle }
    }

    private static func aliases(roster: [MentionCandidate], gatewayLabel: (GatewayID) -> String) -> [Suggestion] {
        let tags = roster.map { MentionResolution.mentionTag(friendlyTitle: $0.friendlyTitle, name: $0.name, handle: $0.handle) }
        return zip(roster, tags).map { candidate, tag in
            let duplicate = tags.filter { $0 == tag }.count > 1
            // Hex encoding is reversible and collision-free, unlike a truncated hash or label.
            let suffix = candidate.route.id.utf8.map { String(format: "%02x", $0) }.joined()
            return Suggestion(candidate: candidate, alias: duplicate ? "\(tag)-\(suffix)" : tag,
                              gatewayLabel: gatewayLabel(candidate.route.gatewayID))
        }
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
