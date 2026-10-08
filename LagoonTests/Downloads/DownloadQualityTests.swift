import Foundation
import Testing
@testable import Lagoon

/// Download size estimates, the effective quality, and the artwork URL
/// parser behind `ImageCache`'s offline match.
@Suite("Download quality estimates")
struct DownloadQualityTests {
    @Test func originalEstimateReturnsTheSourceSize() {
        #expect(DownloadQuality.original.estimatedBytes(sourceSize: 12_345, runTimeTicks: Ticks.ticks(3_600)) == 12_345)
    }

    @Test func highEstimateForATwoHourFilmCountsBothVideoAndAudio() {
        // (8 Mbps video + 256 kbps audio) / 8 bits × 7,200 s.
        let bytes = DownloadQuality.high.estimatedBytes(sourceSize: nil, runTimeTicks: Ticks.ticks(7_200))
        #expect(bytes == 7_430_400_000)
    }

    @Test func estimateIsNilWithoutARuntime() {
        #expect(DownloadQuality.high.estimatedBytes(sourceSize: nil, runTimeTicks: nil) == nil)
        #expect(DownloadQuality.high.estimatedBytes(sourceSize: nil, runTimeTicks: 0) == nil)
    }

    @Test func effectiveTakesTheOriginalWhenATranscodeWouldNotBeSmaller() {
        // The high transcode would be bigger than this source, so take the original.
        let effective = DownloadQuality.high.effective(sourceSize: 500_000_000, runTimeTicks: Ticks.ticks(7_200))
        #expect(effective == .original)
    }

    @Test func effectiveKeepsTheTranscodeWhenItWouldActuallyBeSmaller() {
        let effective = DownloadQuality.high.effective(sourceSize: 40_000_000_000, runTimeTicks: Ticks.ticks(7_200))
        #expect(effective == .high)
    }

    @Test func effectiveNeverChangesTheOriginalRequest() {
        #expect(DownloadQuality.original.effective(sourceSize: 1, runTimeTicks: 1) == .original)
    }

    @Test func orderedPutsTheDefaultFirstWhenTranscodingIsAllowed() {
        let ordered = DownloadQuality.ordered(default: .standard, transcodingAllowed: true)
        #expect(ordered == [.standard, .original, .high])
    }

    @Test func orderedDropsTranscodeQualitiesWhenNotAllowed() {
        let ordered = DownloadQuality.ordered(default: .high, transcodingAllowed: false)
        #expect(ordered == [.original])
    }

    @Test func orderedKeepsAllCasesWhenTheDefaultAlreadyLeadsThem() {
        let ordered = DownloadQuality.ordered(default: .original, transcodingAllowed: true)
        #expect(ordered == [.original, .high, .standard])
    }
}

@Suite("Download artwork key")
struct DownloadArtworkKeyTests {
    @Test func parsesAPosterURLIgnoringItsQuery() {
        let url = URL(string: "https://example.com/Items/abc123/Images/Primary?maxWidth=600&tag=xyz")!
        let key = DownloadArtworkKey.parse(url)
        #expect(key?.imageItemID == "abc123")
        #expect(key?.type == "Primary")
    }

    @Test func parsesABackdropURLWhoseTypeCarriesASlash() {
        let url = URL(string: "https://example.com/Items/abc123/Images/Backdrop/0?maxWidth=1280")!
        let key = DownloadArtworkKey.parse(url)
        #expect(key?.imageItemID == "abc123")
        #expect(key?.type == "Backdrop/0")
    }

    @Test func indexKeyIsCaseInsensitive() {
        #expect(DownloadArtworkKey.indexKey(imageItemID: "ABC", type: "Primary")
            == DownloadArtworkKey.indexKey(imageItemID: "abc", type: "primary"))
    }

    @Test func returnsNilForAURLWithNoItemsImagesPath() {
        let url = URL(string: "https://example.com/System/Info")!
        #expect(DownloadArtworkKey.parse(url) == nil)
    }
}
