import Foundation
import Testing
@testable import Lagoon

/// Landscape cards ask for `.thumb` but fall back to a poster, as
/// jellyfin-web does.
@Suite("Item image fallback")
struct ItemImageFallbackTests {
    private func client() -> JellyfinClient {
        let client = JellyfinClient(deviceId: "image-fallback-test")
        client.configure(serverURL: URL(string: "https://media.test/jellyfin")!)
        return client
    }

    private func item(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    private func path(_ url: URL?) -> String? {
        url.map { $0.path + "?" + ($0.query ?? "") }
    }

    @Test func thumbPrefersThumbThenBackdropThenPoster() throws {
        let client = client()

        let withThumb = try item(#"{"Id":"m","Type":"Movie","ImageTags":{"Primary":"p","Thumb":"t"},"BackdropImageTags":["b"]}"#)
        #expect(path(client.imageURL(for: withThumb, kind: .thumb, maxWidth: 360))
            == "/jellyfin/Items/m/Images/Thumb?maxWidth=360&quality=90&tag=t")

        let withBackdrop = try item(#"{"Id":"m","Type":"Movie","ImageTags":{"Primary":"p"},"BackdropImageTags":["b"]}"#)
        #expect(path(client.imageURL(for: withBackdrop, kind: .thumb, maxWidth: 360))
            == "/jellyfin/Items/m/Images/Backdrop/0?maxWidth=360&quality=90&tag=b")

        // King Lear (1910) on the demo: a poster and nothing else.
        let posterOnly = try item(#"{"Id":"m","Type":"Movie","ImageTags":{"Primary":"p"}}"#)
        #expect(path(client.imageURL(for: posterOnly, kind: .thumb, maxWidth: 360))
            == "/jellyfin/Items/m/Images/Primary?maxWidth=360&quality=90&tag=p")
    }

    @Test func anEpisodeWithoutAStillFallsBackToTheSeriesPoster() throws {
        let client = client()
        let episode = try item(#"{"Id":"e","Type":"Episode","SeriesId":"s","SeriesPrimaryImageTag":"sp"}"#)
        #expect(path(client.imageURL(for: episode, kind: .thumb, maxWidth: 360))
            == "/jellyfin/Items/s/Images/Primary?maxWidth=360&quality=90&tag=sp")
    }

    @Test func anItemWithNoArtworkAtAllResolvesToNothing() throws {
        let client = client()
        let bare = try item(#"{"Id":"m","Type":"Movie","Name":"Nothing"}"#)
        #expect(client.imageURL(for: bare, kind: .thumb, maxWidth: 360) == nil)
    }
}
