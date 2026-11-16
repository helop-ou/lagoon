import Foundation

/// Every date a seasonal theme or surprise goes by, in one place. Each is a
/// month and a day with no year, so all of them come round again by
/// themselves: the year is only ever read from the clock.
nonisolated enum SeasonalCalendar {
    /// A day of the year.
    struct Day: Equatable, Comparable, Sendable {
        let month: Int
        let day: Int

        init(month: Int, day: Int) {
            self.month = month
            self.day = day
        }

        /// The day `date` falls on.
        init?(of date: Date, calendar: Calendar) {
            let parts = calendar.dateComponents([.month, .day], from: date)
            guard let month = parts.month, let day = parts.day else { return nil }
            self.init(month: month, day: day)
        }

        static func < (earlier: Day, later: Day) -> Bool {
            (earlier.month, earlier.day) < (later.month, later.day)
        }

        func isDay(of date: Date, calendar: Calendar) -> Bool {
            Day(of: date, calendar: calendar) == self
        }
    }

    /// A run of days, both ends included. One whose last day comes before
    /// its first runs over New Year.
    struct Stretch: Equatable, Sendable {
        let first: Day
        let last: Day

        private var runsOverNewYear: Bool { last < first }

        func contains(_ date: Date, calendar: Calendar) -> Bool {
            guard let day = Day(of: date, calendar: calendar) else { return false }
            return runsOverNewYear ? day >= first || day <= last : day >= first && day <= last
        }

        /// The year the run holding `date` began in, which tells one from
        /// the next and keeps one that runs over New Year a single run. Nil
        /// outside it.
        func startYear(holding date: Date, calendar: Calendar) -> Int? {
            guard contains(date, calendar: calendar), let day = Day(of: date, calendar: calendar) else { return nil }
            let year = calendar.component(.year, from: date)
            return runsOverNewYear && day <= last ? year - 1 : year
        }
    }

    /// The Spooky theme's season.
    static let spooky = Stretch(first: Day(month: 10, day: 1), last: Day(month: 10, day: 31))
    /// The night the ghosts come in flocks.
    static let halloween = Day(month: 10, day: 31)
    /// The Winter theme's season.
    static let winter = Stretch(first: Day(month: 12, day: 1), last: Day(month: 1, day: 6))
    /// The day of the fireworks.
    static let newYear = Day(month: 1, day: 1)
}
