import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Lagoon

/// HEL-262: repeated stalls just kept happening, with no way out for the
/// viewer. Three in a minute bring up an offer, once per item.
@Suite("Playback quality offer")
@MainActor
struct PlaybackQualityOfferTests {
    /// Which of the stalls, at these times, brought up the offer.
    private func offers(at times: [TimeInterval]) -> [Bool] {
        var policy = PlaybackQualityOfferPolicy()
        return times.map { policy.recordStall(at: $0) }
    }

    @Test func threeStallsInAMinuteBringUpTheOfferOnce() {
        // Once per item, whatever the answer.
        #expect(offers(at: [0, 20, 40, 45, 50]) == [false, false, true, false, false])
    }

    @Test func stallsSpreadOverLongerAreNotARun() {
        // The first has left the window by the third.
        #expect(offers(at: [0, 50, 61, 70]) == [false, false, false, true])
    }

    @Test func acceptingRunsTheSwitchOnceAndDismissingDoesNot() {
        let offer = PlaybackQualityOffer()
        var accepted = 0
        offer.onAccept = { accepted += 1 }
        // Nothing up: Back goes on to its next meaning.
        #expect(!offer.dismiss())
        offer.accept()
        #expect(accepted == 0)

        offer.present()
        #expect(offer.isVisible)
        offer.accept()
        offer.accept()
        #expect(accepted == 1)
        #expect(!offer.isVisible)

        offer.present()
        #expect(offer.dismiss())
        #expect(!offer.isVisible)
        #expect(accepted == 1)
    }

    /// Writes the card to the test container's tmp folder for a look.
    @Test func theCardRenders() throws {
        let card = PlayerQualityOfferCard(onAccept: {}, onDismiss: {})
            .padding(40)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0 && image.height > 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quality-offer-card.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        print("QUALITY_OFFER_CARD \(url.path)")
    }
}
