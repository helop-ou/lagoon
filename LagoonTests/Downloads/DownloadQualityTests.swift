import Foundation
import Testing
@testable import Lagoon

/// Pure coverage for what a download would cost and which quality is
/// actually fetched, plus the artwork URL parser that backs the
/// offline artwork match in `ImageCache`.
@Suite("Download quality estimates")
struct DownloadQualityTests {
    @Test func originalEstimateReturnsTheSourceSize() {
        #expect(DownloadQuality.original.estimatedBytes(sourceSize: 12_345, runTimeTicks: Ticks.ticks(3_600)) == 12_345)
    }

    @Test func highEstimateForATwoHourFilmIsAboutSevenPointFourGB() {
        let bytes = DownloadQuality.high.estimatedBytes(sourceSize: nil, runTimeTicks: Ticks.ticks(7_200))
        let gigabytes = Double(bytes ?? 0) / 1_000_000_000
        #expect(gigabytes > 7.0 && gigabytes < 7.8)
    }

    @Test func estimateIsNilWithoutARuntime() {
        #expect(DownloadQuality.high.estimatedBytes(sourceSize: nil, runTimeTicks: nil) == nil)
        #expect(DownloadQuality.high.estimatedBytes(sourceSize: nil, runTimeTicks: 0) == nil)
    }

    @Test func effectiveTakesTheOriginalWhenATranscodeWouldNotBeSmaller() {
        // An already-efficient small source: the high transcode's estimate
        // would exceed it, so the fast path takes the original directly.
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
