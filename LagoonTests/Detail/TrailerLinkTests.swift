import Foundation
import Testing
@testable import Lagoon

@Suite("Trailer link")
struct TrailerLinkTests {
    private func trailer(_ address: String, _ name: String? = nil) -> RemoteTrailer {
        RemoteTrailer(url: URL(string: address)!, name: name)
    }

    @Test func findsTheVideoIDInEveryCommonYouTubeAddress() {
        let addresses = [
            "https://www.youtube.com/watch?v=N-J-HR3quc4",
            "http://youtube.com/watch?feature=share&v=N-J-HR3quc4",
            "https://m.youtube.com/watch?v=N-J-HR3quc4",
            "https://youtu.be/N-J-HR3quc4",
            "https://www.youtube.com/embed/N-J-HR3quc4",
            "https://www.youtube-nocookie.com/embed/N-J-HR3quc4",
            "https://www.youtube.com/shorts/N-J-HR3quc4",
        ]
        for address in addresses {
            #expect(TrailerLink.youTubeID(in: URL(string: address)!) == "N-J-HR3quc4", "\(address)")
        }
    }

    @Test func rejectsWhatIsNotAYouTubeVideo() {
        let addresses = [
            "https://www.youtube.com/channel/UCabcdef",
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=a b",
            "https://notyoutube.com/watch?v=N-J-HR3quc4",
            "https://vimeo.com/123456789",
        ]
        for address in addresses {
            #expect(TrailerLink.youTubeID(in: URL(string: address.replacingOccurrences(of: " ", with: "%20"))!) == nil, "\(address)")
        }
    }

    @Test func prefersTheOfficialTrailerThenAnyTrailerOverTeasers() {
        let teaser = trailer("https://youtu.be/teaser0001", "Teaser")
        let clip = trailer("https://youtu.be/clip000001", "Behind the scenes")
        let second = trailer("https://youtu.be/trailer002", "Trailer 2")
        let official = trailer("https://youtu.be/official01", "Official Trailer")
        #expect(TrailerLink.preferred([teaser, clip, second, official]) == official)
        #expect(TrailerLink.preferred([teaser, clip, second]) == second)
        #expect(TrailerLink.preferred([teaser, clip]) == clip)
        // Unnamed trailers keep the server's order.
        let first = trailer("https://youtu.be/unnamed001")
        #expect(TrailerLink.preferred([first, trailer("https://youtu.be/unnamed002")]) == first)
        #expect(TrailerLink.preferred([]) == nil)
    }

    @Test func opensTheYouTubeAppOnTVAndTheWebLinkOnThePhone() {
        let youTube = trailer("https://youtu.be/N-J-HR3quc4")
        let vimeo = trailer("https://vimeo.com/123456789", "Official Trailer")
        #if os(tvOS)
        #expect(TrailerLink.destination(for: youTube)?.absoluteString == "youtube://watch/N-J-HR3quc4")
        // No browser on tvOS: a trailer elsewhere cannot open.
        #expect(TrailerLink.destination(for: vimeo) == nil)
        #expect(TrailerLink.preferred([vimeo, youTube]) == youTube)
        #else
        #expect(TrailerLink.destination(for: youTube)?.absoluteString == "https://www.youtube.com/watch?v=N-J-HR3quc4")
        #expect(TrailerLink.destination(for: vimeo) == vimeo.url)
        #endif
    }

    @Test func aBadEntryDropsAloneAndTheItemStillDecodes() throws {
        let json = #"""
        {"Id":"film","Type":"Movie","RemoteTrailers":[
            {"Name":"No address"},
            {"Url":"https://www.youtube.com/watch?v=N-J-HR3quc4","Name":"Official Trailer"},
            {"Url":42}
        ]}
        """#
        let item = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        #expect(item.remoteTrailers?.map(\.name) == ["Official Trailer"])

        let broken = #"{"Id":"film","Type":"Movie","RemoteTrailers":"nope"}"#
        let fallback = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(broken.utf8))
        #expect(fallback.remoteTrailers == nil)
    }
}
