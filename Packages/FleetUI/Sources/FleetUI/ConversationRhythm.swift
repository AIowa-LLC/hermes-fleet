import SwiftUI

/// Refinement Phase 2 — transcript timestamp rhythm.
///
/// Before: every gateway-stamped message carried its own full date and time,
/// so a long chat read as a column of identical "9/4/25, 5:29 PM" lines.
/// Now messages group into runs and the date moves into a quiet separator:
///
/// - A run is consecutive messages from the same speaker (user or
///   assistant) less than `groupGap` apart. Only a run's LAST message shows
///   its time, and only the time ("5:29 PM").
/// - A separator ("Today · 5:29 PM", "Yesterday · 9:02 AM", "Sep 4 · 5:29 PM")
///   opens the transcript's first stamped message and any message after a
///   day change or a gap of at least `separatorGap`.
///
/// Live, unstamped rows never get a time or a separator (U6: never
/// fabricate a time). Pure over the bounded display window.
enum ConversationRhythm {
    static let groupGap: TimeInterval = 5 * 60
    static let separatorGap: TimeInterval = 60 * 60

    struct Marks: Equatable {
        /// Rows that show their (time-only) timestamp.
        var timestampRowIDs: Set<String> = []
        /// Separator dates, keyed by the row the separator sits above.
        var separators: [String: Date] = [:]
    }

    static func marks(for rows: [ConversationRow], calendar: Calendar = .current) -> Marks {
        var marks = Marks()
        let speaking = rows.filter { $0.kind == .user || $0.kind == .assistant }
        var previousStamp: Double?
        for (index, row) in speaking.enumerated() {
            guard let stamp = row.timestamp else { continue }
            let date = Date(timeIntervalSince1970: stamp)
            if let previous = previousStamp {
                let previousDate = Date(timeIntervalSince1970: previous)
                if !calendar.isDate(previousDate, inSameDayAs: date) || stamp - previous >= separatorGap {
                    marks.separators[row.id] = date
                }
            } else {
                marks.separators[row.id] = date
            }
            previousStamp = stamp

            let next = index + 1 < speaking.count ? speaking[index + 1] : nil
            let endsRun: Bool
            if let next {
                if next.kind != row.kind {
                    endsRun = true
                } else if let nextStamp = next.timestamp {
                    endsRun = nextStamp - stamp >= groupGap
                        || !calendar.isDate(Date(timeIntervalSince1970: nextStamp), inSameDayAs: date)
                } else {
                    // The next message is live and unstamped: this row is the
                    // last one that can say when the run happened.
                    endsRun = true
                }
            } else {
                endsRun = true
            }
            if endsRun { marks.timestampRowIDs.insert(row.id) }
        }
        return marks
    }

    /// "5:29 PM" — the date lives in the separator.
    static func timeText(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened)
    }

    /// "Today · 5:29 PM", "Yesterday · 9:02 AM", "Sep 4 · 5:29 PM",
    /// "Sep 4, 2025 · 5:29 PM" (other years).
    static func separatorText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return "\(day) · \(time)"
    }
}

/// The quiet, centered date line that opens a run of the transcript.
struct ConversationTimeSeparator: View {
    @Environment(\.fleetTheme) private var theme
    let date: Date

    var body: some View {
        Text(ConversationRhythm.separatorText(date))
            .font(.caption2.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.vertical, FleetTheme.spacingXs)
            .frame(maxWidth: .infinity)
            .padding(.top, FleetTheme.spacingSm)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("fleet.conversation.separator")
    }
}
