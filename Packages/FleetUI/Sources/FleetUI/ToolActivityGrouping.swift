import Foundation

/// FB5 (TestFlight Build 90 feedback #5 — "Too much room for tool calling."
/// / "It should look more a chat than technical reporting."): once a tool
/// call has FINISHED, its full-height inspector card is dead weight in the
/// transcript — the outcome is already known. This groups a run of
/// consecutive, COMPLETED tool calls (folding in any completed reasoning
/// aside interleaved between them) into ONE compact, chat-like block, so a
/// multi-tool turn costs one row instead of N.
///
/// Pure and side-effect free: the view model's flat `[ConversationRow]`
/// transcript goes in, the list of blocks the transcript should RENDER comes
/// out. Nothing here mutates a row, owns view state, or talks to the
/// gateway — the view keys its own per-group disclosure `@State` off
/// `ToolActivityGroup.id`.
public enum ToolActivityGrouping {

    /// Whether this row can fold into a compact tool-activity group: a
    /// FINISHED tool call that carries no artifact and no image-generation
    /// lifecycle of its own. Card D (generated-image citations) and Card E
    /// (the branded in-flight animation) presentation is preserved EXACTLY
    /// — a row carrying either never folds, per the plan's explicit
    /// carve-out.
    ///
    /// A tool row still running (`ConversationRow.toolIsInFlight`, the VM's
    /// own ground truth — set true on `tool.start`/`tool.generating`/
    /// `tool.progress` and false on `tool.complete`) stays its own live row
    /// so a working session never reads as idle.
    public static func isGroupableCompletedTool(_ row: ConversationRow) -> Bool {
        guard row.kind == .tool else { return false }
        guard !row.toolIsInFlight else { return false }
        guard row.generationActivity == nil else { return false }
        guard (row.artifacts ?? []).isEmpty else { return false }
        return true
    }

    /// A completed reasoning aside: a textless, non-streaming row carrying
    /// only reasoning detail. Absorbed into whatever tool run it falls
    /// between without ever rendering (or breaking) its own block — this is
    /// forward-compatible with a gateway ordering that reasons BETWEEN tool
    /// calls (today's client only ever buffers reasoning into the final
    /// assistant bubble; see `ConversationViewModel.appendThinking`), so a
    /// future interleaved-reasoning frame is never rendered as its own
    /// full-height row either.
    public static func isAbsorbableReasoning(_ row: ConversationRow) -> Bool {
        row.kind == .assistant && row.text.isEmpty && !row.isStreaming
            && !(row.detail ?? "").isEmpty
    }

    /// Group a flat row list into transcript blocks.
    ///
    /// A run of one or more consecutive groupable rows (completed tool
    /// calls, with any absorbable reasoning folded in) becomes ONE
    /// `.toolGroup`. Everything else — user/assistant text, a still-running
    /// tool, a row carrying an artifact or generation activity, a failed
    /// turn's error row, an approval banner (never part of the transcript
    /// row list at all) — renders as its own `.row`, byte-for-byte
    /// unchanged. A run never crosses a non-tool, non-absorbable row, so
    /// separate turns (and a turn's own reply) are never merged together.
    public static func group(_ rows: [ConversationRow]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var run: [ConversationRow] = []

        func flush() {
            guard !run.isEmpty else { return }
            defer { run = [] }
            if run.contains(where: { $0.kind == .tool }) {
                blocks.append(.toolGroup(ToolActivityGroup(rows: run)))
            } else {
                // Defensive fallback — a run only opens on a tool row below,
                // so this never fires in practice; never drop content.
                blocks.append(contentsOf: run.map(TranscriptBlock.row))
            }
        }

        for row in rows {
            if isGroupableCompletedTool(row) {
                run.append(row)
            } else if isAbsorbableReasoning(row), !run.isEmpty {
                // Only absorbed INSIDE a run a tool call already opened —
                // reasoning with no surrounding tool activity is ordinary
                // assistant content and renders on its own.
                run.append(row)
            } else {
                flush()
                blocks.append(.row(row))
            }
        }
        flush()
        return blocks
    }
}

/// One rendered unit in the transcript after grouping: either an ordinary
/// `ConversationRow`, unchanged, or one collapsed run of completed tool
/// activity.
public enum TranscriptBlock: Identifiable, Equatable, Sendable {
    case row(ConversationRow)
    case toolGroup(ToolActivityGroup)

    public var id: String {
        switch self {
        case .row(let row): return row.id
        case .toolGroup(let group): return group.id
        }
    }
}

/// One collapsed run of completed tool activity (FB5): the individual rows
/// it folds — tool calls plus any absorbed completed-reasoning aside — with
/// the deterministic counts/summary the compact row and its VoiceOver label
/// are built from.
///
/// Pure value, no view state: the view keys its own expansion `@State` off
/// `id`. Disclosure renders exactly the folded rows through the SAME row
/// views already used today, so nothing the current UI shows for a tool
/// call is newly hidden or newly exposed.
public struct ToolActivityGroup: Identifiable, Equatable, Sendable {
    /// Stable identity: the LAST folded row's id. Using the tail (not the
    /// head) keeps the transcript's own "scroll to the last row" behavior
    /// working unmodified when that last row is the one folded into this
    /// group (`ConversationViewModel`/`ConversationView` key auto-follow off
    /// `transcript.last?.id`).
    public let id: String
    /// Every row folded into this group, in transcript order — tool rows
    /// AND any absorbed reasoning aside.
    public let rows: [ConversationRow]

    public init(rows: [ConversationRow]) {
        precondition(!rows.isEmpty, "ToolActivityGroup requires at least one row")
        self.id = rows[rows.count - 1].id
        self.rows = rows
    }

    /// The folded tool calls (excludes an absorbed reasoning aside).
    public var toolRows: [ConversationRow] { rows.filter { $0.kind == .tool } }

    public var totalCount: Int { toolRows.count }

    /// Tool calls whose row was marked failed. No wire frame sets
    /// `ConversationRow.isFailed` on a `.tool` row today (`tool.complete`
    /// carries no error/status field — see `ConversationEvent.toolComplete`
    /// and `GatewayConversationClient`), so this is currently always 0 in
    /// the shipped app; the grouping still respects the field so a future
    /// failure source is never silently swallowed into a "successful"
    /// group, and it is what the unit tests exercise directly.
    public var failedCount: Int { toolRows.filter(\.isFailed).count }

    public var isAllSucceeded: Bool { failedCount == 0 }

    /// Unique tool names, first-seen order — the summary's name list.
    public var toolNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in toolRows where seen.insert(row.text).inserted {
            out.append(row.text)
        }
        return out
    }

    /// `"terminal, memory +2"` — the first two unique names, "+N" for the
    /// rest. Deterministic: first-seen order, never sorted or shuffled.
    public var toolNameSummary: String {
        let names = toolNames
        guard names.count > 2 else { return names.joined(separator: ", ") }
        let shown = names.prefix(2).joined(separator: ", ")
        return "\(shown) +\(names.count - 2)"
    }

    /// `"Used 4 tools"` / `"Used 1 tool"`.
    public var headline: String {
        "Used \(totalCount) tool\(totalCount == 1 ? "" : "s")"
    }

    /// The compact row's visible caption: `"Used 4 tools · terminal, memory
    /// +2"`, or `"Used 4 tools · 1 failed"` once any fold failed — a
    /// failure is never hidden inside a clean-looking group.
    public var summaryLine: String {
        if failedCount > 0 {
            return "\(headline) · \(failedCount) failed"
        }
        return toolNames.isEmpty ? headline : "\(headline) · \(toolNameSummary)"
    }

    /// VoiceOver phrasing — spelled out, never abbreviated with "+N":
    /// `"Used 4 tools: terminal, memory, and 2 more."` /
    /// `"Used 4 tools: 1 failed."`.
    public var accessibilitySummary: String {
        if failedCount > 0 {
            return "\(headline): \(failedCount) failed."
        }
        let names = toolNames
        guard !names.isEmpty else { return "\(headline)." }
        if names.count <= 2 {
            return "\(headline): \(names.joined(separator: ", "))."
        }
        let shown = names.prefix(2).joined(separator: ", ")
        let rest = names.count - 2
        return "\(headline): \(shown), and \(rest) more."
    }
}
