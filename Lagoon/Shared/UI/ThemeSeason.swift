import Foundation

/// A stretch of the year with a theme of its own: Spooky through October,
/// Winter from 1 December to 6 January.
nonisolated struct ThemeSeason: Equatable, Sendable {
    let theme: AppTheme
    /// The year it began in, which tells one winter from the next and keeps
    /// a winter one season on both sides of New Year.
    let year: Int

    /// What a profile's choice during this season is stored as.
    var id: String { "\(theme.rawValue).\(year)" }

    static func current(on date: Date, calendar: Calendar = .current) -> ThemeSeason? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        switch (month, day) {
        case (10, _): return ThemeSeason(theme: .spooky, year: year)
        case (12, _): return ThemeSeason(theme: .winter, year: year)
        case (1, ...6): return ThemeSeason(theme: .winter, year: year - 1)
        default: return nil
        }
    }
}
