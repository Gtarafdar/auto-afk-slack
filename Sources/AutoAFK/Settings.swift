import Foundation
import Combine

/// Slack's default status-duration presets (mirrors the Slack status picker).
enum TimerPreset: String, CaseIterable, Identifiable, Codable {
    case dontClear
    case thirtyMinutes
    case oneHour
    case fourHours
    case today
    case thisWeek
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dontClear:     return "Don't clear"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour:       return "1 hour"
        case .fourHours:     return "4 hours"
        case .today:         return "Today"
        case .thisWeek:      return "This week"
        case .custom:        return "Custom"
        }
    }

    /// Computes the Unix `status_expiration` value relative to `now`.
    /// Returns 0 for "Don't clear" (Slack treats 0 as no expiration).
    /// `customMinutes` is only used when `self == .custom`.
    func expiration(from now: Date = Date(), customMinutes: Int = 60) -> Int {
        let calendar = Calendar.current
        switch self {
        case .dontClear:
            return 0
        case .thirtyMinutes:
            return Int(now.addingTimeInterval(30 * 60).timeIntervalSince1970)
        case .oneHour:
            return Int(now.addingTimeInterval(60 * 60).timeIntervalSince1970)
        case .fourHours:
            return Int(now.addingTimeInterval(4 * 60 * 60).timeIntervalSince1970)
        case .today:
            // End of the current day (local time).
            let startOfDay = calendar.startOfDay(for: now)
            if let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) {
                return Int(endOfDay.timeIntervalSince1970)
            }
            return Int(now.addingTimeInterval(8 * 60 * 60).timeIntervalSince1970)
        case .thisWeek:
            // End of the current week (local time).
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                return Int(interval.end.timeIntervalSince1970 - 1)
            }
            return Int(now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970)
        case .custom:
            let minutes = max(1, customMinutes)
            return Int(now.addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970)
        }
    }
}

/// User-facing, non-secret settings persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Keys {
        static let enabled = "afk.enabled"
        static let message = "afk.message"
        static let emoji = "afk.emoji"
        static let timerPreset = "afk.timerPreset"
        static let customMinutes = "afk.customMinutes"
        static let selectedWorkspaceIDs = "afk.selectedWorkspaceIDs"
    }

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var message: String {
        didSet { defaults.set(message, forKey: Keys.message) }
    }
    @Published var emoji: String {
        didSet { defaults.set(emoji, forKey: Keys.emoji) }
    }
    @Published var timerPreset: TimerPreset {
        didSet { defaults.set(timerPreset.rawValue, forKey: Keys.timerPreset) }
    }
    @Published var customMinutes: Int {
        didSet { defaults.set(customMinutes, forKey: Keys.customMinutes) }
    }
    /// Workspace (team) IDs the AFK status should be applied to.
    @Published var selectedWorkspaceIDs: Set<String> {
        didSet { defaults.set(Array(selectedWorkspaceIDs), forKey: Keys.selectedWorkspaceIDs) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.message: "Away from keyboard",
            Keys.emoji: ":zzz:",
            Keys.timerPreset: TimerPreset.dontClear.rawValue,
            Keys.customMinutes: 60
        ])

        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.message = defaults.string(forKey: Keys.message) ?? "Away from keyboard"
        self.emoji = defaults.string(forKey: Keys.emoji) ?? ":zzz:"
        self.timerPreset = TimerPreset(rawValue: defaults.string(forKey: Keys.timerPreset) ?? "")
            ?? .dontClear
        self.customMinutes = defaults.integer(forKey: Keys.customMinutes)
        let ids = defaults.stringArray(forKey: Keys.selectedWorkspaceIDs) ?? []
        self.selectedWorkspaceIDs = Set(ids)
        if self.customMinutes <= 0 { self.customMinutes = 60 }
    }

    /// Normalizes the emoji to Slack's `:shortcode:` form.
    var normalizedEmoji: String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") { return trimmed }
        return ":\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))):"
    }

    func currentExpiration() -> Int {
        timerPreset.expiration(customMinutes: customMinutes)
    }
}
