import Foundation
import Testing
@testable import Lagoon

/// Repeated stalls bring up an offer of a lower quality: three in a minute,
/// once per item.
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

    /// Stalls as the controller sees them: a running count, read once per
    /// tick, so one reading can carry several.
    private func offersAfterStalls(
        isClosed: Bool = false,
        isLocalPlayback: Bool = false,
        isInGroup: Bool = false
    ) -> Bool {
        var policy = PlaybackQualityOfferPolicy()
        let first = PlaybackController.recordStalls(
            2, after: 0, at: 10, in: &policy,
            isClosed: isClosed, isLocalPlayback: isLocalPlayback, isInGroup: isInGroup
        )
        let repeated = PlaybackController.recordStalls(
            2, after: 2, at: 11, in: &policy,
            isClosed: isClosed, isLocalPlayback: isLocalPlayback, isInGroup: isInGroup
        )
        let third = PlaybackController.recordStalls(
            3, after: 2, at: 12, in: &policy,
            isClosed: isClosed, isLocalPlayback: isLocalPlayback, isInGroup: isInGroup
        )
        #expect(!first)
        #expect(!repeated)
        return third
    }

    @Test func aStreamThatKeepsStallingIsOfferedALowerQuality() {
        #expect(offersAfterStalls())
    }

    /// A download has no link to blame, a group's restart is the group's,
    /// and a closed player has nothing to offer it on.
    @Test func noOfferForADownloadAGroupOrAClosedPlayer() {
        #expect(!offersAfterStalls(isLocalPlayback: true))
        #expect(!offersAfterStalls(isInGroup: true))
        #expect(!offersAfterStalls(isClosed: true))
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
}
