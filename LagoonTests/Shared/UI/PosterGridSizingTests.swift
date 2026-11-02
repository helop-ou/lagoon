#if os(iOS)
import SwiftUI
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

    /// An open iPhone Duo is regular both ways and takes the iPad's larger
    /// cards, three across its 669-point inner screen instead of five.
    @Test func anOpenDuoGetsTheLargerCards() {
        let minimum = PosterGridSizing.baseMinimum(.regular, .regular)
        #expect(minimum == Metrics.padGridPosterMinimum)
        let count = PosterGridSizing.columnCount(
            availableWidth: 669 - Metrics.screenGutter * 2,
            baseMinimum: minimum,
            scaledPosterWidth: Metrics.posterWidth,
            spacing: Metrics.cardSpacing
        )
        #expect(count == 3)
    }

    /// A landscape Pro Max is regular wide only, so it keeps phone cards.
    @Test(arguments: [
        (UserInterfaceSizeClass?.some(.regular), UserInterfaceSizeClass?.some(.compact)),
        (.compact, .regular),
        (.compact, .compact),
        (nil, nil),
    ])
    func anythingElseGetsPhoneCards(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) {
        #expect(PosterGridSizing.baseMinimum(horizontal, vertical) == Metrics.phoneGridPosterMinimum)
    }
}
#endif
