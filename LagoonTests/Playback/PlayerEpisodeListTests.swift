import Foundation
import Testing
@testable import Lagoon

/// The player's Episodes list and its Picture in Picture button.
@Suite("Player episode list")
struct PlayerEpisodeListTests {
    private func episode(_ id: String, number: Int, name: String? = nil, season: Int = 4) throws -> MediaItem {
        let named = name.map { #","Name":"\#($0)""# } ?? ""
        return try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"""
        {"Id":"\#(id)","Type":"Episode","SeriesId":"s","SeriesName":"The Rookie","SeasonId":"s4",\#
        "ParentIndexNumber":\#(season),"IndexNumber":\#(number)\#(named)}
        """#.utf8))
    }

    private func movie(_ id: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie"}"#.utf8))
    }

    @Test func aSeriesEpisodeListsItsSeasonAndAMovieListsNothing() throws {
        #expect(PlayerEpisodeList.source(for: try episode("e2", number: 2), queue: .series)
            == .season(seriesId: "s", seasonId: "s4"))
        #expect(PlayerEpisodeList.source(for: try movie("m"), queue: .series) == .none)
        let list = try #require(PlayQueueList(entries: [.init(media: try movie("m"))]))
        #expect(PlayerEpisodeList.source(for: try movie("m"), queue: .list(list)) == .queue(list))
    }

    @Test func theSeasonKeepsTheServersOrderAndMarksThePlayingEpisode() throws {
        let episodes = [
            try episode("e1", number: 1, name: "Life and Death"),
            try episode("e2", number: 2, name: "Five Minutes"),
            try episode("e3", number: 3),
        ]
        let list = try #require(PlayerEpisodeList.season(episodes, current: episodes[1]))
        #expect(list.rows.map(\.media.id) == ["e1", "e2", "e3"])
        #expect(list.rows.map(\.isCurrent) == [false, true, false])
        #expect(list.current?.media.id == "e2")
        #expect(list.rows[1].title == "S4 E2 · Five Minutes")
        #expect(list.rows[2].title == "S4 E3")
        #expect(list.rows.allSatisfy { $0.detail == nil })
        #expect(list.heading == "The Rookie · Season 4")
    }

    /// A season that does not hold the playing episode is not its season.
    @Test func aSeasonWithoutThePlayingEpisodeIsNoList() throws {
        let episodes = [try episode("e1", number: 1)]
        #expect(PlayerEpisodeList.season(episodes, current: try episode("e9", number: 9)) == nil)
    }

    /// A playlist can hold one title twice, so the place marks the playing
    /// entry, and choosing an entry moves the queue there.
    @Test func aListMarksItsPositionAndNamesTheSeriesOfItsEpisodes() throws {
        let pilot = try episode("e1", number: 1)
        let entries: [PlayQueueList.Entry] = [.init(media: try movie("m")), .init(media: pilot), .init(media: pilot)]
        let queue = try #require(PlayQueueList(entries: entries, position: 2))
        let list = PlayerEpisodeList.queue(queue)
        #expect(list.rows.map(\.isCurrent) == [false, false, true])
        #expect(list.rows.map(\.detail) == [nil, "The Rookie", "The Rookie"])
        #expect(list.rows.map(\.title) == ["m", "S4 E1", "S4 E1"])
        #expect(queue.moved(to: 1)?.position == 1)
        #expect(queue.moved(to: 3) == nil)
    }

    @Test func pictureInPictureShowsWhereItCanStartOrStop() {
        #expect(PlayerPictureInPictureButton.state(isPossible: true, isActive: false, isAvailable: true) == .start)
        #expect(PlayerPictureInPictureButton.state(isPossible: false, isActive: true, isAvailable: true) == .stop)
        #expect(PlayerPictureInPictureButton.state(isPossible: true, isActive: true, isAvailable: true) == .stop)
        #expect(PlayerPictureInPictureButton.state(isPossible: false, isActive: false, isAvailable: true) == nil)
        #expect(PlayerPictureInPictureButton.state(isPossible: true, isActive: false, isAvailable: false) == nil)
        #expect(PlayerPictureInPictureButton.start.systemImage == "pip.enter")
        #expect(PlayerPictureInPictureButton.stop.systemImage == "pip.exit")
    }
}
