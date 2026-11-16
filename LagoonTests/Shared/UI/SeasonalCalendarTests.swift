import Foundation
import Testing
@testable import Lagoon

@Suite("Seasonal calendar")
struct SeasonalCalendarTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Tallinn")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Twenty years from now and a leap year among them: no date here names
    /// a year, so none of it runs out.
    private static let years = Array(2026...2046)

    @Test(arguments: years)
    func everySeasonComesRoundEachYear(year: Int) {
        let calendar = Self.calendar
        func season(_ year: Int, _ month: Int, _ day: Int) -> ThemeSeason? {
            ThemeSeason.current(on: Self.date(year, month, day), calendar: calendar)
        }
        #expect(season(year, 9, 30) == nil)
        #expect(season(year, 10, 1) == ThemeSeason(theme: .spooky, year: year))
        #expect(season(year, 10, 31) == ThemeSeason(theme: .spooky, year: year))
        #expect(season(year, 11, 1) == nil)
        #expect(season(year, 11, 30) == nil)
        #expect(season(year, 12, 1) == ThemeSeason(theme: .winter, year: year))
        #expect(season(year, 12, 31) == ThemeSeason(theme: .winter, year: year))
        // One winter on both sides of New Year, and a new one the year after.
        #expect(season(year + 1, 1, 1) == ThemeSeason(theme: .winter, year: year))
        #expect(season(year + 1, 1, 6) == ThemeSeason(theme: .winter, year: year))
        #expect(season(year + 1, 1, 7) == nil)
        #expect(season(year + 1, 2, 29) == nil)
        #expect(season(year + 1, 12, 1)?.id != season(year, 12, 1)?.id)
    }

    @Test(arguments: years)
    func theNewYearAndHalloweenNightComeRoundEachYear(year: Int) {
        let calendar = Self.calendar
        #expect(NewYear.year(on: Self.date(year, 12, 31), calendar: calendar) == nil)
        #expect(NewYear.year(on: Self.date(year + 1, 1, 1, 0), calendar: calendar) == year + 1)
        #expect(NewYear.year(on: Self.date(year + 1, 1, 2), calendar: calendar) == nil)
        #expect(NewYear.secondsUntilMidnight(from: Self.date(year, 12, 31, 23), calendar: calendar) == 3600)
        #expect(NewYear.secondsUntilMidnight(from: Self.date(year, 12, 30, 23), calendar: calendar) == nil)
        #expect(NewYear.secondsUntilMidnight(from: Self.date(year + 1, 1, 1, 23), calendar: calendar) == nil)

        #expect(!GhostFlight.isHalloweenNight(Self.date(year, 10, 30, 23), calendar: calendar))
        #expect(!GhostFlight.isHalloweenNight(Self.date(year, 10, 31, 16), calendar: calendar))
        #expect(GhostFlight.isHalloweenNight(Self.date(year, 10, 31, 17), calendar: calendar))
        #expect(GhostFlight.isHalloweenNight(Self.date(year, 11, 1, 5), calendar: calendar))
        #expect(!GhostFlight.isHalloweenNight(Self.date(year, 11, 1, 6), calendar: calendar))
        #expect(!GhostFlight.isHalloweenNight(Self.date(year, 11, 2, 2), calendar: calendar))
    }

    @Test func aStretchHoldsBothItsEndsAndNothingOutsideThem() {
        let calendar = Self.calendar
        let stretch = SeasonalCalendar.Stretch(
            first: SeasonalCalendar.Day(month: 3, day: 10), last: SeasonalCalendar.Day(month: 4, day: 2)
        )
        #expect(!stretch.contains(Self.date(2028, 3, 9), calendar: calendar))
        #expect(stretch.contains(Self.date(2028, 3, 10, 0), calendar: calendar))
        #expect(stretch.contains(Self.date(2028, 3, 31), calendar: calendar))
        #expect(stretch.contains(Self.date(2028, 4, 2, 23), calendar: calendar))
        #expect(!stretch.contains(Self.date(2028, 4, 3, 0), calendar: calendar))
        #expect(stretch.startYear(holding: Self.date(2028, 4, 1), calendar: calendar) == 2028)
        #expect(stretch.startYear(holding: Self.date(2028, 4, 3), calendar: calendar) == nil)
    }

    @Test func aStretchOverNewYearIsOneRunNamedForTheYearItBeganIn() {
        let calendar = Self.calendar
        let stretch = SeasonalCalendar.Stretch(
            first: SeasonalCalendar.Day(month: 12, day: 20), last: SeasonalCalendar.Day(month: 1, day: 3)
        )
        #expect(!stretch.contains(Self.date(2030, 12, 19), calendar: calendar))
        #expect(stretch.startYear(holding: Self.date(2030, 12, 20), calendar: calendar) == 2030)
        #expect(stretch.startYear(holding: Self.date(2031, 1, 3), calendar: calendar) == 2030)
        #expect(stretch.startYear(holding: Self.date(2031, 1, 4), calendar: calendar) == nil)
        #expect(stretch.startYear(holding: Self.date(2031, 6, 1), calendar: calendar) == nil)
    }

    /// The day is the viewer's own, not Greenwich's.
    @Test func aDayTurnsAtTheViewersOwnMidnight() throws {
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        // One moment: already New Year's Day in Auckland, still the eve in Honolulu.
        let moment = try #require(auckland.date(from: DateComponents(year: 2031, month: 1, day: 1, hour: 9)))
        #expect(NewYear.year(on: moment, calendar: auckland) == 2031)
        #expect(NewYear.year(on: moment, calendar: honolulu) == nil)
        #expect(NewYear.secondsUntilMidnight(from: moment, calendar: honolulu) != nil)
    }
}
