import Foundation

/// Generates only well-defined Hermes schedule forms. Validation stays on the gateway.
public enum BotRoutineSchedule {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case once = "Once", hourly = "Hourly", daily = "Daily", weekly = "Weekly", custom = "Custom"
        public var id: String { rawValue }
    }

    public static func value(mode: Mode, date: Date, hour: Int, minute: Int,
                             weekday: Int, intervalHours: Int, raw: String) -> String? {
        if mode == .custom { return raw }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        switch mode {
        case .once: return ISO8601DateFormatter().string(from: date)
        case .hourly:
            guard (1...24).contains(intervalHours) else { return nil }
            return "every \(intervalHours)h"
        case .daily: return "\(minute) \(hour) * * *"
        case .weekly:
            guard (0...6).contains(weekday) else { return nil }
            return "\(minute) \(hour) * * \(weekday)"
        case .custom: return raw
        }
    }
}

public enum HiddenBotActivity {
    /// A live activity state is evidence; roster timestamps alone are not unread counts.
    public static func hasSignal(_ bot: FleetBot) -> Bool {
        guard bot.botModeMetadata?.hidden == true else { return false }
        return [.working, .thinking, .usingTool, .needsAttention].contains(bot.activity)
    }
}
