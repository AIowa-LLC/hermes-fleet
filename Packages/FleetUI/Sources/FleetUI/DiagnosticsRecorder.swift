import Foundation
import Observation
import FleetCore

/// P0-A "Report a Problem": a bounded, in-memory ring of recent faults the
/// diagnostics report renders.
///
/// Design constraints:
/// - **Redacted at record time.** `record` stores `Redaction.safeDiagnosticText(detail)`
///   so a secret cannot even sit in memory, and the renderer re-redacts on the
///   way out (belt and braces).
/// - **Bounded.** At most `limit` entries are retained; the newest are kept and
///   the oldest evicted, so a long session cannot grow the ring without end.
/// - **In-memory only.** Never persisted: a report is a snapshot of this run,
///   and a persisted fault log would be a second, un-audited data store.
@MainActor
@Observable
public final class DiagnosticsRecorder {
    /// One recorded fault.
    public struct Entry: Sendable, Equatable {
        /// When the fault was observed (supplied by the caller — the recorder
        /// never invents a timestamp).
        public let at: Date
        /// Short category (e.g. "Gateway connection").
        public let category: String
        /// One-line, already-redacted detail.
        public let detail: String

        public init(at: Date, category: String, detail: String) {
            self.at = at
            self.category = category
            self.detail = detail
        }
    }

    /// Maximum entries retained (clamped to at least 1).
    public let limit: Int

    /// Entries oldest-first (insertion order).
    public private(set) var entries: [Entry] = []

    public init(limit: Int = 30) {
        self.limit = max(1, limit)
    }

    /// Record a fault. The category and detail are redacted here AND at render
    /// time; a caller that already redacted is redacted again, harmlessly.
    public func record(category: String, detail: String, at date: Date = Date()) {
        entries.append(Entry(
            at: date,
            category: Redaction.safeDiagnosticText(category),
            detail: Redaction.safeDiagnosticText(detail)))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// A copy of the current ring, oldest-first (safe to hand to a renderer).
    public func snapshot() -> [Entry] {
        entries
    }

    /// Drop every recorded fault (local-data clear).
    public func clear() {
        entries.removeAll()
    }
}