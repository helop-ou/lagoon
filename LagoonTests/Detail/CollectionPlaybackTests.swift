import Foundation
import Testing
@testable import Lagoon

/// Where the collection page's Play button starts, and the order it plays.
@Suite("Collection playback")
@MainActor
struct CollectionPlaybackTests {
    private func item(_ id: String, type: String = "Movie", played: Bool = false, percent: Double? = nil, ticks: Int64? = nil) throws -> MediaItem {
        var userData = #""Played":\#(played)"#
        if let percent { userData += #","PlayedPercentage":\#(percent)"# }
        if let ticks { userData += #","PlaybackPositionTicks":\#(ticks)"# }
        let json = #"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)","UserData":{\#(userData)}}"#
        return try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    @Test func aFreshCollectionPlaysFromItsFirstTitle() throws {
        let playback = try #require(CollectionPlayback(items: [try item("Cars"), try item("Cars 2"), try item("Cars 3")]))
        #expect(playback.title.id == "Cars")
        #expect(!playback.resumes)
        // Play already starts at the top, so From Beginning would repeat it.
        #expect(playback.fromBeginning == nil)
        #expect(playback.queue.next?.media.id == "Cars 2")
    }

    @Test func playStartsAtTheFirstUnwatchedTitle() throws {
        let playback = try #require(CollectionPlayback(items: [
            try item("Cars", played: true), try item("Cars 2"), try item("Cars 3"),
        ]))
        #expect(playback.title.id == "Cars 2")
        #expect(!playback.resumes)
        #expect(playback.fromBeginning?.current.media.id == "Cars")
        #expect(playback.caption == "Cars 2")
    }

    @Test func aPartWatchedTitleIsResumedAndNamed() throws {
        let playback = try #require(CollectionPlayback(items: [
            try item("Cars", played: true), try item("Cars 2", percent: 40, ticks: 25_300_000_000), try item("Cars 3"),
        ]))
        #expect(playback.title.id == "Cars 2")
        #expect(playback.resumes)
        #expect(playback.caption == "Cars 2, from 42:10")
        #expect(playback.fromBeginning?.position == 0)
    }

    @Test func theFurthestPartWatchedTitleWins() throws {
        // An abandoned first film must not pull Resume back to the start.
        let playback = try #require(CollectionPlayback(items: [
            try item("Rise", percent: 5, ticks: 3_000_000_000), try item("Dawn", played: true), try item("War", percent: 60, ticks: 40_000_000_000),
        ]))
        #expect(playback.title.id == "War")
    }

    @Test func aWatchedCollectionStartsOver() throws {
        let playback = try #require(CollectionPlayback(items: [try item("A", played: true), try item("B", played: true)]))
        #expect(playback.title.id == "A")
        #expect(!playback.resumes)
        #expect(playback.fromBeginning == nil)
    }

    @Test func aSeriesInsideIsSkippedAndEpisodesStay() throws {
        let playback = try #require(CollectionPlayback(items: [
            try item("Show", type: "Series"), try item("Film"), try item("Special", type: "Episode"),
        ]))
        #expect(playback.queue.entries.map(\.media.id) == ["Film", "Special"])
    }

    @Test func nothingPlayableMeansNoButton() throws {
        #expect(CollectionPlayback(items: [try item("Show", type: "Series")]) == nil)
        #expect(CollectionPlayback(items: []) == nil)
    }

    @Test func playStartsAListQueue() throws {
        let playback = try #require(CollectionPlayback(items: [try item("A", played: true), try item("B")]))
        let player = PlayerItem(list: playback.queue)
        #expect(player.media.id == "B")
        #expect(player.queue == .list(playback.queue))
        #expect(!player.startFromBeginning)
    }

    // MARK: - Order

    @Test func theCollectionsOwnOrderIsRespected() {
        #expect(JellyfinClient.collectionSortBy(displayOrder: "SortName") == "SortName")
        #expect(JellyfinClient.collectionSortBy(displayOrder: "PremiereDate") == "PremiereDate,SortName")
        // A server that does not say keeps release order.
        #expect(JellyfinClient.collectionSortBy(displayOrder: nil) == "PremiereDate,SortName")
        #expect(JellyfinClient.collectionSortBy(displayOrder: "Something new") == "PremiereDate,SortName")
    }

    @Test func aCollectionDecodesItsDisplayOrder() throws {
        let json = #"{"Id":"c","Type":"BoxSet","DisplayOrder":"SortName"}"#
        let collection = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        #expect(collection.displayOrder == "SortName")
        let odd = #"{"Id":"c","Type":"BoxSet","DisplayOrder":7}"#
        #expect(try JellyfinClient.decoder.decode(MediaItem.self, from: Data(odd.utf8)).displayOrder == nil)
    }
}
