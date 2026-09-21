import Foundation

/// Group-turn prompt construction for phone-bridged rooms (Build 76).
///
/// Behavioral port of Hermes Desktop's `group-round-prompt.ts` contract:
/// every member turn is submitted as a framed group prompt carrying the room
/// roster, the member's own identity, and the bounded transcript delta since
/// that member's last delivered turn. Pure and testable — no networking, no
/// UI, no persistence.
public enum BridgedRoomTurnPrompt {
    /// Delta lines delivered per turn (Desktop `GROUP_CHAT_HISTORY_LIMIT`).
    public static let historyLimit = 24

    /// Openers of Hermes' own control frames. A member reply is republished
    /// to every peer inside the submitted prompt text, so a reply that
    /// reproduces one of these trusted shapes would read as harness input to
    /// the peer; the opener is relabelled visibly (the words stay, the exact
    /// trusted shape does not). Genuine user lines are never touched. Kept
    /// in sync with `agent/prompt_builder.py::CONTROL_FRAME_OPENERS` and
    /// Desktop's `MEMBER_CONTROL_FRAME_RE` (which allows an optional `/`
    /// before the OUT-OF-BAND opener).
    private static let controlFrameOpeners: [String] = [
        "OUT-OF-BAND USER MESSAGE", "CONTEXT COMPACTION", "CONTEXT SUMMARY]",
        "PRIOR CONTEXT", "Runtime note:", "System note:", "System:", "SYSTEM]",
        "IMPORTANT:", "Planning state preserved", "ASYNC DELEGATION",
    ]

    private static let controlFrameRelabel = "[member-quoted "

    /// The complete per-turn payload for one member.
    public struct Input {
        public let roomName: String
        public let viewer: BridgedRooms.MemberRef
        public let members: [BridgedRooms.MemberRef]
        public let delta: [BridgedRooms.EventRecord]

        public init(
            roomName: String, viewer: BridgedRooms.MemberRef,
            members: [BridgedRooms.MemberRef], delta: [BridgedRooms.EventRecord]
        ) {
            self.roomName = roomName
            self.viewer = viewer
            self.members = members
            self.delta = delta
        }
    }

    /// The full per-turn payload for one member: participation rules + the
    /// room delta. Rules travel in the turn payload (not SOUL) so every
    /// existing bot can join a group chat without a profile migration.
    public static func build(_ input: Input) -> String {
        let viewer = input.viewer
        let peers = input.members.filter { $0.routeID != viewer.routeID }
        let peerNames = peers.map { peer in
            let handle = "\(peer.displayName) (@\(mentionTag(for: peer)))"
            return "\(handle) [on \(peer.sourceLabel)]"
        }.joined(separator: ", ")

        var lines: [String] = []
        lines.append(
            "[Group chat: \"\(input.roomName)\"] You are @\(mentionTag(for: viewer)), one participant in a group chat with \(peerNames.isEmpty ? "no one else yet" : peerNames) and the user.")
        lines.append("")
        lines.append("New messages in the room since your last turn (oldest first):")
        lines.append(contentsOf: deltaLines(for: input.delta, viewer: viewer, members: input.members).map { "  \($0)" })
        lines.append("")
        lines.append("Rules for this room:")
        lines.append("- Reply with ONE conversational message ONLY if you have something new worth adding: build on what was just said, claim or hand off work, answer a question aimed at you, or report a real result. Keep chatter short (1-3 sentences) — but when you are delivering a result, an answer the user asked for, or substantive work, give it at full quality and length; never thin out real content to fit the room.")
        lines.append("- If you have nothing new to add, reply with exactly \"(pass)\". Passing is good — it lets the conversation settle.")
        lines.append("- Mention a teammate as @name to pull them in; mention @user only for a judgment call or a result the user needs. Do not repeat points already made.")
        lines.append("- Never reveal content from your private 1:1 chats. Your reply text goes to the room verbatim — no preamble, no meta-commentary.")
        return lines.joined(separator: "\n")
    }

    /// Room-log lines as the viewing member sees them, bounded to the last
    /// `historyLimit` delta entries with an explicit omission notice when
    /// the delta was cut (Desktop `formatGroupDeltaLines`).
    public static func deltaLines(
        for events: [BridgedRooms.EventRecord],
        viewer: BridgedRooms.MemberRef,
        members: [BridgedRooms.MemberRef]
    ) -> [String] {
        // Only conversation events feed member context; failure notes and
        // system activity rows are local UI state, not shared conversation.
        let transcript = events.filter { event in
            event.kind == "message.user" || event.kind == "message.member"
        }
        let omitted = transcript.count - historyLimit
        let bounded = omitted > 0 ? Array(transcript.suffix(historyLimit)) : transcript
        var lines = bounded.map { event in
            line(for: event, viewer: viewer, members: members)
        }
        if omitted > 0 {
            lines.insert(
                "… \(omitted) earlier room message\(omitted == 1 ? "" : "s") omitted since your last turn",
                at: 0)
        }
        return lines
    }

    /// One transcript line: `Tony (user): …` / `Writer [beta]: …` /
    /// `Researcher (you): …`. Cross-gateway speakers carry their source so
    /// same-named bots on two machines stay tellable apart; member text is
    /// control-frame relabelled, user text never is.
    private static func line(
        for event: BridgedRooms.EventRecord,
        viewer: BridgedRooms.MemberRef,
        members: [BridgedRooms.MemberRef]
    ) -> String {
        let roster = members.first { $0.routeID == event.actorID }
        if event.actorKind == "user" {
            let name = event.actorDisplayName ?? "User"
            return "\(name) (user): \(event.payloadText ?? "")"
        }
        let display = roster?.displayName ?? event.actorDisplayName ?? event.actorID
        let isSelf = roster?.routeID == viewer.routeID
        // A speaker no longer on the roster keeps its historical attribution
        // (routeID-qualified), never borrowed identity from the viewer.
        let source = (roster != nil && !isSelf) ? " [\(roster?.sourceLabel ?? event.actorProfile ?? "")]" : ""
        let suffix = isSelf ? " (you)" : ""
        let text = relabelControlFrames(in: event.payloadText ?? "")
        return "\(display)\(suffix)\(source): \(text)"
    }

    /// "(pass)" (loosely: pass / (pass) / pass.) or empty = the member
    /// stayed silent (Desktop `isGroupPassText`).
    public static func isPassText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        var body = trimmed
        if body.hasPrefix("(") { body.removeFirst() }
        if body.hasSuffix(")") { body.removeLast() }
        if body.hasSuffix(".") { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("pass") == .orderedSame
    }

    /// Visibly relabel control-frame openers inside quoted member text so a
    /// control-looking string can never be promoted into a trusted
    /// instruction when forwarded to another participant. Mirrors Desktop's
    /// regex semantics: only the opening `[` is replaced (the words — and
    /// any `/` before the OUT-OF-BAND opener — stay verbatim).
    public static func relabelControlFrames(in text: String) -> String {
        var result = text
        for opener in controlFrameOpeners {
            // `[/OPENER` (slash form) and `[OPENER` (plain form); the slash
            // survives the relabel exactly as Desktop's single-character
            // replacement leaves it.
            result = result.replacingOccurrences(
                of: "[/\(opener)", with: "\(controlFrameRelabel)/\(opener)",
                options: [.caseInsensitive])
            result = result.replacingOccurrences(
                of: "[\(opener)", with: "\(controlFrameRelabel)\(opener)",
                options: [.caseInsensitive])
        }
        return result
    }

    /// The @handle a member is addressed by (Desktop `botMentionTag`):
    /// the slugified friendly name when usable, else the profile handle with
    /// `default` rendered as `hermes`. Reserved words are dropped so a bot
    /// renamed "All" can never hijack the room-wide alias.
    public static func mentionTag(for member: BridgedRooms.MemberRef) -> String {
        for friendly in [member.displayName, member.profile] {
            let forms = mentionNameForms(friendly)
            if let first = forms.first { return first }
        }
        let profile = member.profile.trimmingCharacters(in: .whitespaces)
        return profile.lowercased() == "default" ? "hermes" : profile
    }

    /// Usable mention forms of a friendly name (Desktop
    /// `mentionNameForms`): slug + collapsed variants, reserved words
    /// excluded.
    private static func mentionNameForms(_ value: String) -> [String] {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        let slug = name
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let collapsed = name.components(separatedBy: allowed.inverted).joined()
        var seen = Set<String>()
        var forms: [String] = []
        for form in [slug, collapsed] where !form.isEmpty {
            guard !seen.contains(form) else { continue }
            seen.insert(form)
            let first = form.first!
            guard ("a"..."z").contains(first) || ("0"..."9").contains(first) else { continue }
            guard form.allSatisfy({ allowed.contains($0.unicodeScalars.first!) }) else { continue }
            guard !["all", "everyone", "user", "default", "hermes"].contains(form) else { continue }
            forms.append(form)
        }
        return forms
    }
}
