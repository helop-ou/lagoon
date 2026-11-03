import Foundation
import Testing
@testable import Lagoon

@Suite("Hero info line")
struct HeroFactsTests {
    private func item(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    @Test func aFilmShowsItsYearTwoGenresAndRuntime() throws {
        let film = try item(#"{"Id":"m","Type":"Movie","ProductionYear":2016,"Genres":["Science Fiction","Drama","Mystery"],"RunTimeTicks":69600000000}"#)
        #expect(film.heroFacts == ["2016", "Science Fiction", "Drama", "1 h 56 min"])
    }

    /// A series' runtime is one episode's, which reads as the show's length.
    @Test func aSeriesLeavesOutTheRuntime() throws {
        let series = try item(#"{"Id":"s","Type":"Series","ProductionYear":2023,"Genres":["Drama"],"RunTimeTicks":27000000000}"#)
        #expect(series.heroFacts == ["2023", "Drama"])
    }

    @Test func anEpisodeShowsItsNumberAndName() throws {
        let episode = try item(#"{"Id":"e","Type":"Episode","Name":"Machines","SeriesName":"Silo","ParentIndexNumber":2,"IndexNumber":5,"ProductionYear":2024,"Genres":["Drama"]}"#)
        #expect(episode.heroFacts == ["S2 E5", "Machines"])
    }

    @Test func missingFactsAreLeftOut() throws {
        let film = try item(#"{"Id":"m","Type":"Movie"}"#)
        #expect(film.heroFacts.isEmpty)
    }

    @Test func aStartedTitleSaysWhatIsLeft() throws {
        let film = try item(#"{"Id":"m","Type":"Movie","RunTimeTicks":72000000000,"UserData":{"PlayedPercentage":75}}"#)
        let long = try item(#"{"Id":"m","Type":"Movie","RunTimeTicks":72000000000,"UserData":{"PlayedPercentage":25}}"#)
        let unstarted = try item(#"{"Id":"m","Type":"Movie","RunTimeTicks":72000000000}"#)
        #expect(film.timeRemainingLabel == "30 min left")
        #expect(long.timeRemainingLabel == "1 h 30 min left")
        #expect(unstarted.timeRemainingLabel == nil)
    }

    @Test func aSeerrTitleNamesTwoOfItsGenres() throws {
        let result = try JSONDecoder().decode(SeerrDiscoverResult.self, from: Data(#"""
        {"id":1,"mediaType":"movie","title":"Arrival","releaseDate":"2016-11-11","genreIds":[878,18,9648]}
        """#.utf8))
        let names = [18: "Drama", 878: "Science Fiction", 9648: "Mystery"]
        #expect(result.heroFacts(genreNames: names) == ["2016", "Science Fiction", "Drama"])
        #expect(result.heroFacts(genreNames: [:]) == ["2016"])
    }

    /// An unnamed id is skipped, so a later genre takes its place.
    @Test func aSeerrGenreWithoutANameIsSkipped() throws {
        let result = try JSONDecoder().decode(SeerrDiscoverResult.self, from: Data(#"""
        {"id":1,"mediaType":"tv","name":"Silo","genreIds":[1,18,9648]}
        """#.utf8))
        #expect(result.heroFacts(genreNames: [18: "Drama", 9648: "Mystery"]) == ["Drama", "Mystery"])
    }

    @Test func aMalformedSeerrGenreListDecodesAsNone() throws {
        let result = try JSONDecoder().decode(SeerrDiscoverResult.self, from: Data(#"""
        {"id":1,"mediaType":"movie","title":"Arrival","genreIds":"18"}
        """#.utf8))
        #expect(result.genreIds.isEmpty)
    }
}
