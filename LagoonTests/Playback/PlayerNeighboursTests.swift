import Foundation
import Testing
@testable import Lagoon

/// The title before the playing one and the Episodes list. A collection or
/// playlist answers both from its own entries. A series asks the server.
@Suite("Player neighbours", .serialized)
@MainActor
struct PlayerNeighboursTests {
    private static let host = "neighbours.test"

    private static func item(_ id: String, type: String = "Movie") throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"}"#.utf8))
    }

    private static func episodeJSON(_ number: Int) -> String {
        #"""
        {"Id":"e\#(number)","Name":"Episode \#(number)","Type":"Episode","SeriesId":"show","SeriesName":"The Rookie",\#
        "SeasonId":"season-4","ParentIndexNumber":4,"IndexNumber":\#(number)}
        """#
    }

    private static func episode(_ number: Int) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(episodeJSON(number).utf8))
    }

    /// A season of three, served for both the season and the adjacent query.
    private static func serveSeason() -> JellyfinClient {
        let body = Data(#"{"Items":[\#((1...3).map(episodeJSON).joined(separator: ","))],"TotalRecordCount":3}"#.utf8)
        StubURLProtocol.register(host: host) { _ in (200, [:], body) }
        return StubURLProtocol.makeJellyfinClient(host: host, deviceId: "neighbours-tests")
    }

    private static func seasonRequests() -> Int {
        StubURLProtocol.requests(host: host).count { $0.url?.query()?.contains("SeasonId=season-4") == true }
    }

    @Test func aListAnswersFromItsOwnEntries() throws {
        let client = Self.serveSeason()
        defer { StubURLProtocol.unregister(host: Self.host) }
        let entries = try ["a", "b", "c"].map { PlayQueueList.Entry(media: try Self.item($0)) }
        let list = try #require(PlayQueueList(entries: entries, position: 1))
        let neighbours = PlayerNeighbours()

        neighbours.resolve(around: try Self.item("b"), queue: .list(list), client: client)
        #expect(neighbours.previousItem?.id == "a")
        #expect(neighbours.episodeList == .queue(list))
        #expect(StubURLProtocol.requests(host: Self.host).isEmpty)
    }

    @Test func aMovieOnItsOwnHasNeither() throws {
        let client = Self.serveSeason()
        defer { StubURLProtocol.unregister(host: Self.host) }
        let neighbours = PlayerNeighbours()

        neighbours.resolve(around: try Self.item("film"), queue: .series, client: client)
        #expect(neighbours.previousItem == nil)
        #expect(neighbours.episodeList == nil)
        #expect(StubURLProtocol.requests(host: Self.host).isEmpty)
    }

    /// The next episode of a season already fetched lists at once, so the
    /// Episodes button does not blink out across a hand-off.
    @Test func aSeriesAsksForItsSeasonOnce() async throws {
        let client = Self.serveSeason()
        defer { StubURLProtocol.unregister(host: Self.host) }
        let neighbours = PlayerNeighbours()

        neighbours.resolve(around: try Self.episode(2), queue: .series, client: client)
        #expect(neighbours.episodeList == nil)
        try await Polling.untilMainActor(timeout: .seconds(5)) {
            neighbours.episodeList != nil && neighbours.previousItem != nil
        }
        #expect(neighbours.episodeList?.rows.map(\.media.id) == ["e1", "e2", "e3"])
        #expect(neighbours.episodeList?.current?.media.id == "e2")
        #expect(neighbours.previousItem?.id == "e1")

        neighbours.resolve(around: try Self.episode(3), queue: .series, client: client)
        #expect(neighbours.episodeList?.current?.media.id == "e3")
        #expect(neighbours.previousItem == nil, "the title before is asked for again")
        try await Polling.untilMainActor(timeout: .seconds(5)) { neighbours.previousItem != nil }
        #expect(neighbours.previousItem?.id == "e2")
        #expect(Self.seasonRequests() == 1)
    }

    /// A hand-off forgets the outgoing title's predecessor and keeps the list.
    @Test func aHandOffKeepsTheListAndForgetsTheTitleBefore() throws {
        let client = Self.serveSeason()
        defer { StubURLProtocol.unregister(host: Self.host) }
        let entries = try ["a", "b"].map { PlayQueueList.Entry(media: try Self.item($0)) }
        let list = try #require(PlayQueueList(entries: entries, position: 1))
        let neighbours = PlayerNeighbours()
        neighbours.resolve(around: try Self.item("b"), queue: .list(list), client: client)

        neighbours.forgetPreviousItem()
        #expect(neighbours.previousItem == nil)
        #expect(neighbours.episodeList == .queue(list))
    }

    /// The server's answer for a title that is no longer playing must not
    /// replace what the new title resolved.
    @Test func anAnswerForTheTitleBeforeIsDropped() async throws {
        let client = Self.serveSeason()
        defer { StubURLProtocol.unregister(host: Self.host) }
        let neighbours = PlayerNeighbours()
        neighbours.resolve(around: try Self.episode(2), queue: .series, client: client)

        let entries = try ["a", "b"].map { PlayQueueList.Entry(media: try Self.item($0)) }
        let list = try #require(PlayQueueList(entries: entries, position: 0))
        neighbours.resolve(around: try Self.item("a"), queue: .list(list), client: client)
        try await Task.sleep(for: .milliseconds(300))
        #expect(neighbours.episodeList == .queue(list))
        #expect(neighbours.previousItem == nil)
    }

    @Test func closingStopsWhatIsStillBeingAsked() async throws {
        let client = Self.serveSeason()
        defer { StubURLProtocol.unregister(host: Self.host) }
        let neighbours = PlayerNeighbours()
        neighbours.resolve(around: try Self.episode(2), queue: .series, client: client)

        neighbours.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(neighbours.episodeList == nil)
        #expect(neighbours.previousItem == nil)
    }
}
