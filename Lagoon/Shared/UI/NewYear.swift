import Foundation

/// When the New Year surprise is due, by the viewer's own calendar.
nonisolated enum NewYear {
    /// The year being welcomed, all through 1 January and on no other day.
    static func year(on date: Date, calendar: Calendar = .current) -> Int? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.month == 1, parts.day == 1 else { return nil }
        return parts.year
    }

    /// Seconds until the year turns, on 31 December only.
    static func secondsUntilMidnight(from date: Date, calendar: Calendar = .current) -> TimeInterval? {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard parts.month == 12, parts.day == 31,
              let midnight = calendar.nextDate(
                  after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
              ) else { return nil }
        return midnight.timeIntervalSince(date)
    }
}
