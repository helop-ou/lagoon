import Foundation

/// When the New Year surprise is due, by the viewer's own calendar.
nonisolated enum NewYear {
    /// The year being welcomed, all through New Year's Day and on no other.
    static func year(on date: Date, calendar: Calendar = .current) -> Int? {
        guard SeasonalCalendar.newYear.isDay(of: date, calendar: calendar) else { return nil }
        return SeasonalCalendar.gregorian(on: calendar).component(.year, from: date)
    }

    /// The year the greeting names: this one on New Year's Day, and the next
    /// on any other day, which only a preview asks for.
    static func upcomingYear(on date: Date, calendar: Calendar = .current) -> Int {
        year(on: date, calendar: calendar)
            ?? SeasonalCalendar.gregorian(on: calendar).component(.year, from: date) + 1
    }

    /// Seconds until the year turns, on New Year's Eve only.
    static func secondsUntilMidnight(from date: Date, calendar: Calendar = .current) -> TimeInterval? {
        guard let midnight = calendar.nextDate(
            after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
        ), SeasonalCalendar.newYear.isDay(of: midnight, calendar: calendar) else { return nil }
        return midnight.timeIntervalSince(date)
    }
}
