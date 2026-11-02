import Foundation
import Testing
@testable import Lagoon

@Suite("Unwatched episode count")
struct UnwatchedEpisodeCountTests {
    private func item(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    @Test func aStartedSeriesShowsWhatIsLeft() throws {
        let series = try item(#"{"Id":"s","Type":"Series","UserData":{"PlayedPercentage":50,"UnplayedItemCount":25}}"#)
        #expect(series.unwatchedEpisodeCount == 25)
    }

    /// Otherwise every show in the library carries a count.
    @Test func aSeriesNeverStartedShowsNothing() throws {
        let series = try item(#"{"Id":"s","Type":"Series","UserData":{"PlayedPercentage":0,"UnplayedItemCount":325}}"#)
        #expect(series.unwatchedEpisodeCount == nil)
    }

    @Test func aFinishedSeriesAndOtherTypesShowNothing() throws {
        let finished = try item(#"{"Id":"s","Type":"Series","UserData":{"PlayedPercentage":100,"UnplayedItemCount":0}}"#)
        let movie = try item(#"{"Id":"m","Type":"Movie","UserData":{"PlayedPercentage":40,"UnplayedItemCount":3}}"#)
        #expect(finished.unwatchedEpisodeCount == nil)
        #expect(movie.unwatchedEpisodeCount == nil)
    }
}
