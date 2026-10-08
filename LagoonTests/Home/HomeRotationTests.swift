import Foundation
import Testing
@testable import Lagoon

/// The Home genre and decade spotlights: they must move daily, but never
/// while you are looking.
@Suite("Home rotation")
struct HomeRotationTests {
    private let utc = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let auckland = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return calendar
    }()

    private func date(_ iso: String, in calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? utc
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    private let genres = ["Horror", "Comedy", "Action", "Drama", "Thriller"]

    // MARK: - Stable within a day

    @Test func theSpotlightHoldsStillFromMorningToNight() {
        // Auckland is UTC+12 in August, so this local day straddles a UTC
        // midnight: the day must be the viewer's, not the epoch's.
        let morning = date("2026-08-25 06:00", in: auckland)
        let night = date("2026-08-25 23:30", in: auckland)

        #expect(
            HomeRotation.genre(rankedByWatchHistory: genres, for: morning, calendar: auckland)
                == HomeRotation.genre(rankedByWatchHistory: genres, for: night, calendar: auckland)
        )
        #expect(
            HomeRotation.decade(for: morning, calendar: auckland)
                == HomeRotation.decade(for: night, calendar: auckland)
        )
    }

    @Test func consecutiveDaysNeverRepeatWhileCandidatesRemain() {
        let days = (0..<5).map { date("2026-08-2\($0 + 1) 12:00") }
        let picks = days.compactMap { HomeRotation.genre(rankedByWatchHistory: genres, for: $0, calendar: utc) }

        // Five days over five candidates is a full cycle with no repeats.
        #expect(Set(picks).count == 5)
    }

    // MARK: - What it picks from

    @Test func itChoosesOnlyFromTheGenresYouActuallyWatch() {
        // The tail is one-off viewing, not a taste worth a row.
        let ranked = genres + ["Documentary", "Western", "Musical"]
        let year = (0..<40).map { date("2026-08-25 12:00").addingTimeInterval(Double($0) * 86_400) }
        let picks = Set(year.compactMap {
            HomeRotation.genre(rankedByWatchHistory: ranked, for: $0, calendar: utc)
        })

        #expect(picks.isSubset(of: Set(genres)))
    }

    @Test func aViewerWithNoHistoryGetsNoGenreRow() {
        #expect(HomeRotation.genre(rankedByWatchHistory: [], for: date("2026-08-25 12:00"), calendar: utc) == nil)
    }

    @Test func aSingleWatchedGenreIsStillOfferedRatherThanSuppressed() {
        let pick = HomeRotation.genre(
            rankedByWatchHistory: ["Horror"],
            for: date("2026-08-25 12:00"),
            calendar: utc
        )

        #expect(pick == "Horror")
    }

    // MARK: - Decades

    @Test func decadesStopBeforeTheCurrentOne() {
        // Recently Added already covers the current decade.
        let year = (0..<40).map { date("2026-08-25 12:00").addingTimeInterval(Double($0) * 86_400) }
        let picks = Set(year.compactMap { HomeRotation.decade(for: $0, calendar: utc) })

        #expect(picks.isSubset(of: [1970, 1980, 1990, 2000, 2010]))
        #expect(!picks.contains(2020))
    }

    // MARK: - Ranking

    @Test func genresRankByHowOftenYouWatchThem() throws {
        let items = try [
            #"{"Id":"1","Type":"Movie","Genres":["Horror","Thriller"]}"#,
            #"{"Id":"2","Type":"Movie","Genres":["Horror"]}"#,
            #"{"Id":"3","Type":"Movie","Genres":["Horror","Comedy"]}"#,
            #"{"Id":"4","Type":"Movie","Genres":["Comedy"]}"#,
        ].map { try JellyfinClient.decoder.decode(MediaItem.self, from: Data($0.utf8)) }

        #expect(HomeRotation.rankGenres(byWatchHistory: items) == ["Horror", "Comedy", "Thriller"])
    }

    @Test func tiesBreakOnNameSoTheRankingDoesNotJumpBetweenLoads() throws {
        // Dictionary order is not stable, so ties need an explicit break.
        let items = try [
            #"{"Id":"1","Type":"Movie","Genres":["Western","Action","Musical"]}"#,
        ].map { try JellyfinClient.decoder.decode(MediaItem.self, from: Data($0.utf8)) }

        #expect(HomeRotation.rankGenres(byWatchHistory: items) == ["Action", "Musical", "Western"])
    }

    // MARK: - What "Because You Watched" is willing to name itself after

    @Test func demoReelsAreNotSomethingYouWatched() throws {
        // Demo discs, test patterns and trailers must not seed recommendations.
        let demo = try seed(runTimeMinutes: 6)
        let film = try seed(runTimeMinutes: 118)
        let comedyEpisode = try seed(runTimeMinutes: 22)

        #expect(!HomeCuratedRows.isSubstantialSeed(demo))
        #expect(HomeCuratedRows.isSubstantialSeed(film))
        // The shortest thing anyone actually sits down to still counts.
        #expect(HomeCuratedRows.isSubstantialSeed(comedyEpisode))
    }

    @Test func anUnknownRuntimeIsGivenTheBenefitOfTheDoubt() throws {
        // Servers do not always report a runtime; unknown is not short.
        let unknown = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"x","Type":"Movie","Name":"Untimed"}"#.utf8)
        )

        #expect(HomeCuratedRows.isSubstantialSeed(unknown))
    }

    private func seed(runTimeMinutes: Int) throws -> MediaItem {
        let ticks = Int64(runTimeMinutes) * 60 * 10_000_000
        return try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"x","Type":"Movie","Name":"Seed","RunTimeTicks":\#(ticks)}"#.utf8)
        )
    }
}
