import Foundation
import Testing
@testable import Lagoon

/// What the player's transport and Info tab say about a Jellyfin item and
/// the source it plays.
@Suite("Player item info")
struct PlayerItemInfoTests {
    private let client: JellyfinClient = {
        let client = JellyfinClient(deviceId: "player-info-test")
        client.configure(serverURL: URL(string: "https://media.test")!)
        return client
    }()

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JellyfinClient.decoder.decode(Value.self, from: Data(json.utf8))
    }

    private func episode() throws -> MediaItem {
        try decode(#"""
        {
          "Id":"e1", "Name":"Pilot", "Type":"Episode", "SeriesName":"The 100",
          "ParentIndexNumber":1, "IndexNumber":1, "RunTimeTicks":25800000000,
          "ProductionYear":2014, "Genres":["Drama","Sci-Fi","Mystery","Action"],
          "OfficialRating":"TV-14", "Overview":"Ninety-seven years on."
        }
        """#)
    }

    private func source() throws -> MediaSource {
        try decode(#"""
        {
          "Id":"src", "Bitrate":18400000,
          "MediaStreams":[
            {"Type":"Video","Codec":"hevc","Width":3840,"Height":1600,
             "VideoRangeType":"DOVIWithHDR10","RealFrameRate":23.976},
            {"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true,
             "Profile":"Dolby Digital Plus + Dolby Atmos"}
          ]
        }
        """#)
    }

    @Test func anEpisodeIsHeadlinedByItsSeries() throws {
        let info = PlayerItemInfo(for: try episode(), source: try source(), client: client, extras: .none)

        #expect(info.title == "The 100")
        #expect(info.subtitle == "S1 E1 · Pilot")
        #expect(info.overview == "Ninety-seven years on.")
    }

    @Test func theFactsRunFromRuntimeToRating() throws {
        let info = PlayerItemInfo(for: try episode(), source: try source(), client: client, extras: .none)

        #expect(info.facts == [
            "43 min", "2014", "HEVC (4K DV)", "Dolby Digital+ Atmos 5.1",
            "18.4 Mbps", "23.976 fps", "Drama, Sci-Fi, Mystery", "TV-14",
        ])
        #expect(info.videoSummary == "HEVC · 4K · DV · 3840×1600 · 23.976 fps")
    }

    @Test func whatTheServerDidNotSayIsLeftOut() throws {
        let movie: MediaItem = try decode(#"{"Id":"m1","Name":"Cars","Type":"Movie"}"#)
        let bare: MediaSource = try decode(#"{"Id":"src"}"#)

        let info = PlayerItemInfo(for: movie, source: bare, client: client, extras: .none)

        #expect(info.title == "Cars")
        #expect(info.subtitle == nil)
        #expect(info.facts.isEmpty)
        #expect(info.videoSummary == nil)
        #expect(info.chapters.isEmpty)
        #expect(info.trickplay == nil)
        #expect(info.segments.isEmpty)
    }

    /// A chapter keeps the number the server listed it under, wherever its
    /// start puts it on the transport.
    @Test func chaptersAreOrderedByStartAndNumberedAsTheServerListedThem() throws {
        let extras: JellyfinClient.PlaybackExtras = try decode(#"""
        {"Chapters":[
          {"StartPositionTicks":0,"Name":"Cold Open"},
          {"StartPositionTicks":6000000000,"Name":"Credits"},
          {"StartPositionTicks":3000000000}
        ]}
        """#)

        let info = PlayerItemInfo(for: try episode(), source: try source(), client: client, extras: extras)

        #expect(info.chapters == [
            PlayerChapter(id: 0, name: "Cold Open", start: 0),
            PlayerChapter(id: 2, start: 300),
            PlayerChapter(id: 1, name: "Credits", start: 600),
        ])
    }

    @Test func theSegmentsHandedInAreTheOnesShown() throws {
        let intro = MediaSegment(id: "intro", kind: .intro, start: 10, end: 70)

        let info = PlayerItemInfo(
            for: try episode(), source: try source(), client: client, extras: .none, segments: [intro]
        )

        #expect(info.segments == [intro])
    }
}
