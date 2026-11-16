import Foundation

/// A stretch of the year with a theme of its own. `SeasonalCalendar` says
/// when each runs.
nonisolated struct ThemeSeason: Equatable, Sendable {
    let theme: AppTheme
    /// The year it began in, which tells one winter from the next and keeps
    /// a winter one season on both sides of New Year.
    let year: Int

    /// What a profile's choice during this season is stored as.
    var id: String { "\(theme.rawValue).\(year)" }

    static func current(on date: Date, calendar: Calendar = .current) -> ThemeSeason? {
        let seasons: [(AppTheme, SeasonalCalendar.Stretch)] = [
            (.spooky, SeasonalCalendar.spooky), (.winter, SeasonalCalendar.winter),
        ]
        for (theme, stretch) in seasons {
            if let year = stretch.startYear(holding: date, calendar: calendar) {
                return ThemeSeason(theme: theme, year: year)
            }
        }
        return nil
    }
}
