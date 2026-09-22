import Foundation
import Testing
#if os(tvOS)
import TVServices
#endif
@testable import Lagoon

/// The facts the Top Shelf derives. The extension has no library access or
/// credentials, so the App Group snapshot is all it will ever know.
@Suite("Top Shelf payload")
struct TopShelfPayloadTests {
    #if os(tvOS)
    private func item(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    // MARK: - The context line

    @Test func anEpisodeNamesTheEpisodeBecauseTheArtworkOnlyNamesTheSeries() throws {
        let episode = try item("""
        {"Id":"e","Type":"Episode","Name":"Bad Traffic","SeriesName":"Slow Horses",
         "ParentIndexNumber":1,"IndexNumber":5,"RunTimeTicks":36000000000,
         "UserData":{"PlayedPercentage":50.0}}
        """)

        // railTitle is the *series* for an episode.
        #expect(episode.railTitle == "Slow Horses")
        #expect(episode.topShelfContext == "Continue Watching · S1 E5")
    }

    @Test func aMovieSaysHowMuchIsLeftRatherThanHowLongItIs() throws {
        // Two hours, 75% watched: 30 minutes left, not "2 h 0 min".
        let movie = try item("""
        {"Id":"m","Type":"Movie","Name":"Dune","RunTimeTicks":72000000000,
         "UserData":{"PlayedPercentage":75.0}}
        """)

        #expect(movie.topShelfContext == "Continue Watching · 30 min left")
    }

    @Test func aLongRemainderIsSpelledInHoursAndMinutes() throws {
        let movie = try item("""
        {"Id":"m","Type":"Movie","Name":"Dune","RunTimeTicks":72000000000,
         "UserData":{"PlayedPercentage":10.0}}
        """)

        #expect(movie.topShelfContext == "Continue Watching · 1 h 48 min left")
    }

    @Test func withoutAResumePositionTheFramingStandsAlone() throws {
        // playbackProgress ignores anything at or above 95%.
        let almostDone = try item("""
        {"Id":"m","Type":"Movie","Name":"Dune","RunTimeTicks":72000000000,
         "UserData":{"PlayedPercentage":99.0}}
        """)
        let untouched = try item("""
        {"Id":"m","Type":"Movie","Name":"Dune","RunTimeTicks":72000000000}
        """)

        #expect(almostDone.topShelfContext == "Continue Watching")
        #expect(untouched.topShelfContext == "Continue Watching")
    }

    // MARK: - The capability badges

    @Test func dolbyVisionAndAtmosBecomeTheirBadges() throws {
        let movie = try item("""
        {"Id":"m","Type":"Movie","MediaSources":[{"Id":"s","MediaStreams":[
            {"Type":"Video","Width":3840,"VideoRangeType":"DOVIWithHDR10"},
            {"Type":"Audio","Codec":"truehd","Profile":"Dolby TrueHD + Atmos","Channels":8}
        ]}]}
        """)

        let options = try #require(movie.topShelfMediaOptions)
        let badges = TVTopShelfCarouselItem.MediaOptions(rawValue: options)
        #expect(badges.contains(.videoResolution4K))
        #expect(badges.contains(.videoColorSpaceDolbyVision))
        #expect(badges.contains(.audioDolbyAtmos))
        // Dolby Vision is its own colour space: provide only one.
        #expect(!badges.contains(.videoColorSpaceHDR))
        #expect(!badges.contains(.videoResolutionHD))
    }

    @Test func ordinaryHDStaysUnbadgedApartFromItsResolution() throws {
        let movie = try item("""
        {"Id":"m","Type":"Movie","MediaSources":[{"Id":"s","MediaStreams":[
            {"Type":"Video","Width":1920,"VideoRangeType":"SDR"},
            {"Type":"Audio","Codec":"ac3","Channels":6}
        ]}]}
        """)

        let badges = TVTopShelfCarouselItem.MediaOptions(
            rawValue: try #require(movie.topShelfMediaOptions)
        )
        #expect(badges.contains(.videoResolutionHD))
        #expect(!badges.contains(.videoResolution4K))
        #expect(!badges.contains(.videoColorSpaceHDR))
        #expect(!badges.contains(.audioDolbyAtmos))
    }

    @Test func standardDefinitionEarnsNoResolutionBadgeAtAll() throws {
        // Apple offers only HD and 4K; a DVD rip claims neither.
        let movie = try item("""
        {"Id":"m","Type":"Movie","MediaSources":[{"Id":"s","MediaStreams":[
            {"Type":"Video","Width":720,"VideoRangeType":"SDR"}
        ]}]}
        """)

        let badges = TVTopShelfCarouselItem.MediaOptions(
            rawValue: try #require(movie.topShelfMediaOptions)
        )
        #expect(!badges.contains(.videoResolutionHD))
        #expect(!badges.contains(.videoResolution4K))
    }

    @Test func hdr10IsHDRRatherThanDolbyVision() throws {
        let movie = try item("""
        {"Id":"m","Type":"Movie","MediaSources":[{"Id":"s","MediaStreams":[
            {"Type":"Video","Width":3840,"VideoRangeType":"HDR10"}
        ]}]}
        """)

        let badges = TVTopShelfCarouselItem.MediaOptions(
            rawValue: try #require(movie.topShelfMediaOptions)
        )
        #expect(badges.contains(.videoColorSpaceHDR))
        #expect(!badges.contains(.videoColorSpaceDolbyVision))
    }

    @Test func aServerThatSentNoStreamsYieldsNoBadgesRatherThanEmptyOnes() throws {
        // Nil, not empty: empty would claim "plain SDR stereo".
        let bare = try item(#"{"Id":"m","Type":"Movie","Name":"Dune"}"#)
        let sourceWithoutStreams = try item("""
        {"Id":"m","Type":"Movie","MediaSources":[{"Id":"s"}]}
        """)

        #expect(bare.topShelfMediaOptions == nil)
        #expect(sourceWithoutStreams.topShelfMediaOptions == nil)
    }

    // MARK: - The cross-target contract

    @Test func theSnapshotDecodesIntoTheShapeTheExtensionMirrors() throws {
        // LagoonTopShelf/ContentProvider.swift redeclares these fields by
        // hand, so pin the key names it reads.
        let encoded = try JSONEncoder().encode(
            TopShelfStore.Item(
                id: "abc",
                title: "Dune",
                context: "Continue Watching · 30 min left",
                artwork2x: "abc@2x.jpg",
                artwork1x: "abc@1x.jpg",
                summary: "Paul Atreides",
                genre: "Science Fiction",
                duration: 7200,
                mediaOptions: 5
            )
        )
        let keys = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        ).keys

        #expect(Set(keys) == [
            "id", "title", "context", "artwork2x", "artwork1x",
            "summary", "genre", "duration", "mediaOptions",
        ])
    }
    #endif
}
