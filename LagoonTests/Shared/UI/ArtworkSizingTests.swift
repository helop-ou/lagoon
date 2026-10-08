import Foundation
import Testing
@testable import Lagoon

@Suite("Adaptive artwork sizing")
struct ArtworkSizingTests {
    @Test func usesPhysicalPixelsAndRoundsUp() {
        #expect(ArtworkSizing.pixels(for: 158, displayScale: 3) == 474)
        #expect(ArtworkSizing.pixels(for: 105.3, displayScale: 3) == 316)
        #expect(ArtworkSizing.pixels(for: 280, displayScale: 2) == 560)
    }

    @Test func boundsInvalidOrExcessiveRequests() {
        #expect(ArtworkSizing.pixels(for: .infinity, displayScale: 3) == 1)
        #expect(ArtworkSizing.pixels(for: -10, displayScale: 3) == 1)
        #expect(ArtworkSizing.pixels(for: 9000, displayScale: 3) == 3840)
        #expect(ArtworkSizing.pixels(for: 100, displayScale: 0) == 100)
    }
}
