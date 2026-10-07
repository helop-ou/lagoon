import Foundation
import Testing
@testable import Lagoon

@Suite("Jellyfin URL resolution")
struct JellyfinURLResolutionTests {
    /// The credential travels as a header (`MediaRequestAuthorization`), so no
    /// resolved media URL carries `ApiKey` or `api_key`, even when the server put one in.
    @Test func playbackURLResolutionNeverCarriesTheCredentialInTheQuery() throws {
        let client = JellyfinClient(deviceId: "stream-resolution-test")
        client.configure(serverURL: URL(string: "https://media.test/jellyfin")!)
        client.activateSession(token: "token", userId: "user")

        let directPlay = try mediaSource(#"""
        {
          "Id":"direct", "Container":"mkv",
          "SupportsDirectPlay":true, "SupportsDirectStream":true
        }
        """#)
        let directPlayResult = try client.streamURL(itemId: "item", source: directPlay)
        #expect(directPlayResult.method == .directPlay)
        #expect(directPlayResult.url.path == "/jellyfin/Videos/item/stream")
        #expect(queryValue("ApiKey", in: directPlayResult.url) == nil)
        #expect(queryValue("api_key", in: directPlayResult.url) == nil)

        let directStream = try mediaSource(#"""
        {
          "Id":"remux", "Container":"mov,mp4,m4a",
          "SupportsDirectPlay":false, "SupportsDirectStream":true
        }
        """#)
        let directStreamResult = try client.streamURL(itemId: "item", source: directStream)
        #expect(directStreamResult.method == .directStream)
        #expect(directStreamResult.url.path == "/jellyfin/Videos/item/stream.mov")
        #expect(queryValue("ApiKey", in: directStreamResult.url) == nil)
        #expect(queryValue("api_key", in: directStreamResult.url) == nil)

        let transcode = try mediaSource(#"""
        {
          "Id":"hls", "SupportsDirectPlay":false, "SupportsDirectStream":false,
          "SupportsTranscoding":true,
          "TranscodingUrl":"/Videos/item/master.m3u8?PlaySessionId=session&api_key=legacy-token"
        }
        """#)
        let transcodeResult = try client.streamURL(itemId: "item", source: transcode)
        #expect(transcodeResult.method == .transcode)
        // A server-relative TranscodingUrl keeps the reverse-proxy base path.
        #expect(transcodeResult.url.path == "/jellyfin/Videos/item/master.m3u8")
        // The legacy token is stripped; other query items survive.
        #expect(queryValue("PlaySessionId", in: transcodeResult.url) == "session")
        #expect(queryValue("ApiKey", in: transcodeResult.url) == nil)
        #expect(queryValue("api_key", in: transcodeResult.url) == nil)

        let sidecar = try #require(client.externalSubtitleURL(
            deliveryUrl: "/Videos/item/source/Subtitles/2/0/Stream.srt?api_key=legacy-token"
        ))
        #expect(sidecar.path == "/jellyfin/Videos/item/source/Subtitles/2/0/Stream.srt")
        #expect(queryValue("ApiKey", in: sidecar) == nil)
        #expect(queryValue("api_key", in: sidecar) == nil)

        // A foreign origin is left untouched.
        let externalSidecar = try #require(client.externalSubtitleURL(
            deliveryUrl: "https://subtitles.example.test/item.srt"
        ))
        #expect(externalSidecar.absoluteString == "https://subtitles.example.test/item.srt")

        let tile = try JellyfinClient.decoder.decode(
            TrickplayTileInfo.self,
            from: Data(#"{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":1,"Interval":10000}"#.utf8)
        )
        let trickplay = try #require(client.trickplaySource(
            itemId: "item",
            mediaSourceId: "direct",
            extras: .init(chapters: [], trickplay: ["direct": ["320": tile]])
        ))
        let sheet = try #require(trickplay.sheetURLs.first)
        #expect(queryValue("ApiKey", in: sheet) == nil)
        #expect(queryValue("api_key", in: sheet) == nil)
        // The sheet fetch authenticates through the source's header.
        let sheetAuthorization = try #require(trickplay.authorization)
        #expect(sheetAuthorization.applies(to: sheet))
        #expect(sheetAuthorization.headerValue.contains("Token=\"token\""))
    }

    /// `serverRelativeURL` is what makes a base-path server work for the
    /// routes Jellyfin hands back inside response bodies.
    @Test func serverRelativeRoutesKeepTheBasePath() throws {
        let client = JellyfinClient(deviceId: "relative-route-test")

        client.configure(serverURL: URL(string: "https://media.test/jellyfin/")!)
        #expect(
            client.serverRelativeURL("/videos/abc/master.m3u8?PlaySessionId=s&x=1")?.absoluteString
                == "https://media.test/jellyfin/videos/abc/master.m3u8?PlaySessionId=s&x=1"
        )
        #expect(
            client.serverRelativeURL("videos/abc/main.m3u8")?.absoluteString
                == "https://media.test/jellyfin/videos/abc/main.m3u8"
        )
        // Percent-encoding in the reference survives as encoded bytes.
        #expect(
            client.serverRelativeURL("/Videos/it%20em/Subtitles/2/0/Stream.srt")?.absoluteString
                == "https://media.test/jellyfin/Videos/it%20em/Subtitles/2/0/Stream.srt"
        )
        // An absolute reference is returned as given, wherever it points.
        #expect(
            client.serverRelativeURL("https://cdn.example.test/seg.mp4?k=v")?.absoluteString
                == "https://cdn.example.test/seg.mp4?k=v"
        )

        client.configure(serverURL: URL(string: "https://media.test:8920")!)
        #expect(
            client.serverRelativeURL("/videos/abc/master.m3u8?PlaySessionId=s")?.absoluteString
                == "https://media.test:8920/videos/abc/master.m3u8?PlaySessionId=s"
        )
    }

    @Test func episodePosterUsesSeriesArtworkInsteadOfTheEpisodeStill() throws {
        let client = JellyfinClient(deviceId: "poster-resolution-test")
        client.configure(serverURL: URL(string: "https://media.test/jellyfin")!)
        let episode = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"""
            {
              "Id":"episode-1", "Type":"Episode", "SeriesId":"series-1",
              "ImageTags":{"Primary":"episode-still-tag"},
              "SeriesPrimaryImageTag":"series-poster-tag"
            }
            """#.utf8)
        )

        let poster = try #require(client.imageURL(for: episode, kind: .poster, maxWidth: 400))
        let still = try #require(client.imageURL(for: episode, kind: .primary, maxWidth: 400))

        #expect(poster.path == "/jellyfin/Items/series-1/Images/Primary")
        #expect(URLComponents(url: poster, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name == "tag" && $0.value == "series-poster-tag"
        } == true)
        #expect(still.path == "/jellyfin/Items/episode-1/Images/Primary")
    }

    private func mediaSource(_ json: String) throws -> MediaSource {
        try JellyfinClient.decoder.decode(MediaSource.self, from: Data(json.utf8))
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
