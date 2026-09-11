import Foundation
import Testing
@testable import Lagoon

/// The Home genre and decade spotlights (HEL-120).
///
/// Worth pinning because "it changes sometimes" cannot be verified by looking
/// at the screen once, and the two failure modes are opposites: a rotation
/// that never moves is a fixed row wearing a costume, and one that moves on
/// every appearance makes Home rearrange itself while you are looking at it.
@Suite("Home rotation")
struct HomeRotationTests {
    private let utc = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    private let genres = ["Horror", "Comedy", "Action", "Drama", "Thriller"]

    // MARK: - Stable within a day

    @Test func theSpotlightHoldsStillFromMorningToNight() {
        let morning = date("2026-08-25 06:00")
        let night = date("2026-08-25 23:30")

        #expect(
            HomeRotation.genre(rankedByWatchHistory: genres, for: morning, calendar: utc)
                == HomeRotation.genre(rankedByWatchHistory: genres, for: night, calendar: utc)
        )
        #expect(
            HomeRotation.decade(for: morning, calendar: utc)
                == HomeRotation.decade(for: night, calendar: utc)
        )
    }

    @Test func itMovesOnAtMidnight() {
        // Not an assertion that consecutive days always differ — with five
        // candidates they cannot all — but that a week is not one long day.
        let week = (0..<7).map { date("2026-08-2\($0 + 1) 12:00") }
        let picks = week.map { HomeRotation.genre(rankedByWatchHistory: genres, for: $0, calendar: utc) }

        #expect(Set(picks).count > 1)
    }

    @Test func consecutiveDaysNeverRepeatWhileCandidatesRemain() {
        let days = (0..<5).map { date("2026-08-2\($0 + 1) 12:00") }
        let picks = days.compactMap { HomeRotation.genre(rankedByWatchHistory: genres, for: $0, calendar: utc) }

        // Five candidates stepped one day at a time is a full cycle, so a
        // repeat inside it would mean the seed is not advancing evenly.
        #expect(Set(picks).count == 5)
    }

    // MARK: - What it picks from

    @Test func itChoosesOnlyFromTheGenresYouActuallyWatch() {
        // The tail is one film someone finished once, and is not "theirs" in
        // any sense worth naming a row after.
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
        // Recently Added already covers the current decade, and a "Movies
        // from the 2020s" row beside it would be the same films twice.
        let year = (0..<40).map { date("2026-08-25 12:00").addingTimeInterval(Double($0) * 86_400) }
        let picks = Set(year.compactMap { HomeRotation.decade(for: $0, calendar: utc) })

        #expect(picks.isSubset(of: [1970, 1980, 1990, 2000, 2010]))
        #expect(!picks.contains(2020))
    }

    @Test func theDecadeIsSpelledInFull() {
        // "90s" is ambiguous the moment a library holds anything from 1890.
        #expect(HomeRotation.decadeTitle(startingIn: 1990) == "Movies from the 1990s")
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
        // Dictionary iteration order is not stable, so without an explicit
        // tiebreak the spotlight could change on a reload with no new viewing.
        let items = try [
            #"{"Id":"1","Type":"Movie","Genres":["Western","Action","Musical"]}"#,
        ].map { try JellyfinClient.decoder.decode(MediaItem.self, from: Data($0.utf8)) }

        #expect(HomeRotation.rankGenres(byWatchHistory: items) == ["Action", "Musical", "Western"])
    }

    @Test func nothingWatchedRanksNothing() {
        #expect(HomeRotation.rankGenres(byWatchHistory: []).isEmpty)
    }

    // MARK: - What "Because You Watched" is willing to name itself after

    @Test func demoReelsAreNotSomethingYouWatched() throws {
        // The first run against a real library seeded the row from
        // "Dolby: Core Universe" and recommended five unrelated films off it.
        // A self-hosted library is full of these: demo discs, test patterns,
        // trailers, home video.
        let demo = try seed(runTimeMinutes: 6)
        let film = try seed(runTimeMinutes: 118)
        let comedyEpisode = try seed(runTimeMinutes: 22)

        #expect(!HomeCuratedRows.isSubstantialSeed(demo))
        #expect(HomeCuratedRows.isSubstantialSeed(film))
        // The shortest thing anyone actually sits down to still counts.
        #expect(HomeCuratedRows.isSubstantialSeed(comedyEpisode))
    }

    @Test func anUnknownRuntimeIsGivenTheBenefitOfTheDoubt() throws {
        // Servers do not always report one, and refusing every title with a
        // gap in its metadata is a harsher filter than the one intended.
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
