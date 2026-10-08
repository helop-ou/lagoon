import Foundation
import Testing
@testable import Lagoon

/// A response from an older or odd server must still give a usable item:
/// optional blocks that do not parse are dropped, not fatal.
@Suite("MediaItem decoding")
struct MediaItemDecodingTests {
    private func decode(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    @Test func malformedOptionalBlocksDecodeAsNilAndKeepTheItem() throws {
        let item = try decode(#"""
        {
          "Id": "item-1",
          "Name": "Film",
          "Type": "Movie",
          "UserData": "not an object",
          "MediaSources": 5,
          "People": { "unexpected": true },
          "RemoteTrailers": "none"
        }
        """#)
        #expect(item.id == "item-1")
        #expect(item.name == "Film")
        #expect(item.type == .movie)
        #expect(item.userData == nil)
        #expect(item.mediaSources == nil)
        #expect(item.people == nil)
        #expect(item.remoteTrailers == nil)
    }

    @Test func wellFormedOptionalBlocksStillDecode() throws {
        let item = try decode(#"""
        {
          "Id": "item-1",
          "Type": "Episode",
          "UserData": { "PlaybackPositionTicks": 15000000, "Played": false },
          "MediaSources": [{ "Id": "source-1" }],
          "People": [{ "Id": "person-1", "Name": "Ada", "Type": "Actor" }],
          "RemoteTrailers": [
            { "Url": "https://example.test/trailer", "Name": "Trailer" },
            { "Name": "No address" }
          ]
        }
        """#)
        #expect(item.userData?.playbackPositionTicks == 15_000_000)
        #expect(item.mediaSources?.map(\.id) == ["source-1"])
        #expect(item.people?.first?.name == "Ada")
        #expect(item.remoteTrailers?.map(\.name) == ["Trailer"])
    }

    @Test func aMissingOrUnknownTypeIsOther() throws {
        #expect(try decode(#"{ "Id": "a" }"#).type == .other)
        #expect(try decode(#"{ "Id": "a", "Type": "MusicAlbum" }"#).type == .other)
        #expect(try decode(#"{ "Id": "a", "Type": 7 }"#).type == .other)
    }

    @Test func anItemWithoutAnIdIsRejected() {
        #expect(throws: DecodingError.self) {
            try decode(#"{ "Name": "No id" }"#)
        }
    }
}
