#if os(iOS)
import Foundation
import Testing
@testable import Lagoon

/// Phone poster grids: three across at the default text size, and smaller
/// text never buys a fourth column.
@Suite("Poster grid sizing")
struct PosterGridSizingTests {
    /// A Pro Max in portrait, less the two screen gutters.
    private let proMaxWidth: CGFloat = 440 - Metrics.screenGutter * 2
    /// An SE in portrait, the narrowest phone.
    private let seWidth: CGFloat = 375 - Metrics.screenGutter * 2

    private func columns(_ width: CGFloat, textScale: CGFloat) -> Int {
        PosterGridSizing.columnCount(
            availableWidth: width,
            baseMinimum: Metrics.phoneGridPosterMinimum,
            scaledPosterWidth: Metrics.posterWidth * textScale,
            spacing: Metrics.cardSpacing
        )
    }

    @Test func aPhoneShowsThreeAcrossAtTheDefaultTextSize() {
        #expect(columns(proMaxWidth, textScale: 1) == 3)
        #expect(columns(seWidth, textScale: 1) == 3)
    }

    @Test func smallerTextDoesNotSqueezeInAFourthColumn() {
        // Small and Extra Small scale the caption metric by about 0.9 and 0.8.
        #expect(columns(proMaxWidth, textScale: 0.9) == 3)
        #expect(columns(proMaxWidth, textScale: 0.8) == 3)
    }

    @Test func largerTextStillWidensTheCards() {
        #expect(columns(proMaxWidth, textScale: 1.4) == 2)
    }
}
#endif
