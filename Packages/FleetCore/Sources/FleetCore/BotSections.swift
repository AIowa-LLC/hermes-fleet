import Foundation

/// User-made roster sections — folders the user creates, not folders the
/// topology makes.
///
/// Upstream ground truth (hermes-agent @ 08b140d,
/// apps/desktop/src/plugins/hermes-bots/user-sections.ts):
/// - A section is `{id, name}`; ids are Desktop-minted (`sec-…`) strings.
/// - MEMBERSHIP lives on the bot (`sectionId` in its `hermes-bots` ui_meta),
///   NOT on the section — a bot can only be in one place, deleting a section
///   cannot orphan anybody, and the assignment rides the same profile.yaml
///   sync every other bot setting uses.
/// - "Unassigned" is NOT a section: it is whatever is left, always drawn
///   last, and it is where members of a deleted section land. With no
///   sections at all the roster renders exactly as it did before.
/// - A row whose `sectionId` names a section that no longer exists lands in
///   Unassigned rather than vanishing (splitRosterRows returns EVERY row
///   exactly once) — Fleet must never invent a section for an unknown id.
///
/// Registry location: Desktop persists the registry in plugin-local storage
/// (`bot-sections-v1`); that store never leaves the Desktop app. The only
/// cross-client channel is per-bot ui_meta. Fleet therefore keeps its OWN
/// registry under the SAME key name (`bot-sections-v1`) on the gateway
/// DEFAULT profile's ui_meta — a distinct Fleet-owned value that never
/// races Desktop (Desktop never reads or writes that ui_meta key) — synced
/// with the same per-key CAS as every other ui_meta write, and rendering
/// any `sectionId` it cannot resolve as unassigned (identical rendering
/// parity with a Desktop-only registry).
public struct BotSection: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Normalization + ordering rules for a section registry value, mirroring
/// upstream `normalizeBotSections` exactly: a non-array decodes empty, blank
/// ids/names are dropped, duplicate ids keep the first occurrence, and the
/// array order IS the display order.
public enum BotSectionRegistry {
    public static let metaKey = "bot-sections-v1"

    /// Normalize a decoded registry value (upstream parity).
    public static func normalize(_ value: MetadataValue?) -> [BotSection] {
        guard let entries = value?.arrayValue else { return [] }
        var seen = Set<String>()
        var out: [BotSection] = []
        for entry in entries {
            guard let object = entry.objectValue else { continue }
            let id = (object["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (object["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(BotSection(id: id, name: name))
        }
        return out
    }

    /// Encode a registry back to the wire value (order preserved).
    public static func encode(_ sections: [BotSection]) -> MetadataValue {
        .array(sections.map { section in
            .object([
                "id": .string(section.id),
                "name": .string(section.name),
            ])
        })
    }

    /// Mint a new section id (upstream `sec-<time36>-<rand>` shape).
    public static func newSectionID(now: Double = Date().timeIntervalSince1970) -> String {
        let time36 = String(Int(now), radix: 36)
        let rand = String(Int.random(in: 0..<1_679_616), radix: 36)
        return "sec-\(time36)-\(rand)"
    }

    /// Split bots into ordered section blocks with unassigned last.
    ///
    /// Pure; returns EVERY bot exactly once. A bot whose `sectionId` names a
    /// section that is not in the registry lands in the unassigned block —
    /// never dropped, never given an invented section (upstream
    /// `splitRosterRows` semantics).
    public static func split<T>(_ bots: [T], sectionID: (T) -> String?, sections: [BotSection]) -> [SectionBlock<T>] {
        var byID: [String: [T]] = [:]
        var unassigned: [T] = []
        let known = Set(sections.map(\.id))
        for bot in bots {
            guard let id = sectionID(bot), known.contains(id) else {
                unassigned.append(bot)
                continue
            }
            byID[id, default: []].append(bot)
        }
        var blocks: [SectionBlock<T>] = sections.map { section in
            SectionBlock(id: section.id, name: section.name, rows: byID[section.id] ?? [])
        }
        // Upstream: empty sections still render as (empty) blocks — the
        // registry order is the display order. Unassigned is always last and
        // carries no fabricated "Unassigned" header key (nil id).
        blocks.append(SectionBlock(id: nil, name: "", rows: unassigned))
        return blocks
    }

    /// A registry is meaningful for rendering only when at least one section
    /// exists (with none, the roster renders as it did before sections).
    public static func rendersSections(_ sections: [BotSection]) -> Bool {
        !sections.isEmpty
    }
}

/// One rendered roster block: a user section (id + name + rows) or the
/// trailing unassigned block (`id == nil`, no header).
public struct SectionBlock<T> {
    public let id: String?
    public let name: String
    public let rows: [T]

    public init(id: String?, name: String, rows: [T]) {
        self.id = id
        self.name = name
        self.rows = rows
    }

    public var isUnassigned: Bool { id == nil }
}
