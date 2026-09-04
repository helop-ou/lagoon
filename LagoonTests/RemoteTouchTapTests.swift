#if os(tvOS)
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Siri Remote touch-surface tap")
@MainActor
struct RemoteTouchTapTests {
    @Test func touchTapRecognizerDoesNotConsumeSelectPresses() throws {
        let controller = MenuGateHostingController(rootView: EmptyView())
        controller.loadViewIfNeeded()

        let recognizer = try #require(controller.remoteTouchTapRecognizer)
        #expect(recognizer.allowedPressTypes.isEmpty)
        #expect(
            recognizer.allowedTouchTypes
                == [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        )
        #expect(!recognizer.cancelsTouchesInView)
    }

    @Test func recognizedTouchTapUsesTheLatestHandler() {
        let controller = MenuGateHostingController(rootView: EmptyView())
        var count = 0
        controller.onRemoteTouchTap = { count += 1 }
        controller.remoteTouchTapRecognized()
        #expect(count == 1)

        // UIViewControllerRepresentable refreshes this closure as SwiftUI
        // state changes; the recognizer must not retain the first render's
        // handler.
        controller.onRemoteTouchTap = { count += 10 }
        controller.remoteTouchTapRecognized()
        #expect(count == 11)
    }
}

@Suite("Projected finish time")
struct PlaybackFinishTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func anHourLeftAtNormalSpeedFinishesAnHourFromNow() throws {
        let finish = try #require(PlaybackFinish.date(from: now, remaining: 3600, rate: 1))
        #expect(finish.timeIntervalSince(now) == 3600)
    }

    @Test func doubleSpeedHalvesTheWait() throws {
        let finish = try #require(PlaybackFinish.date(from: now, remaining: 3600, rate: 2))
        #expect(finish.timeIntervalSince(now) == 1800)
    }

    /// The behaviour the ticket actually asks for: holding playback does not
    /// change how much is left, so the finish keeps sliding later.
    @Test func aPausedItemFinishesLaterTheLongerItIsHeld() throws {
        let atPause = try #require(PlaybackFinish.date(from: now, remaining: 1200, rate: 1))
        let aMinuteLater = try #require(
            PlaybackFinish.date(from: now.addingTimeInterval(60), remaining: 1200, rate: 1)
        )
        #expect(aMinuteLater.timeIntervalSince(atPause) == 60)
    }

    /// Playing does not move it, because the clock and the remaining time
    /// advance against each other.
    @Test func playingAtNormalSpeedHoldsTheFinishStill() throws {
        let first = try #require(PlaybackFinish.date(from: now, remaining: 1200, rate: 1))
        let later = try #require(
            PlaybackFinish.date(from: now.addingTimeInterval(60), remaining: 1140, rate: 1)
        )
        #expect(later == first)
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func anUnusableRateProjectsAtNormalSpeed(rate: Double) throws {
        let finish = try #require(PlaybackFinish.date(from: now, remaining: 600, rate: rate))
        #expect(finish.timeIntervalSince(now) == 600)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1.0])
    func anUnusableRemainderHasNoFinish(remaining: Double) {
        #expect(PlaybackFinish.date(from: now, remaining: remaining, rate: 1) == nil)
    }

    /// A live stream reports a duration nothing can project against, so the
    /// label falls back to the time left rather than inventing an answer.
    @Test func aDurationBeyondADayHasNoFinish() {
        let tooFar = PlaybackFinish.longestProjection + 1
        #expect(PlaybackFinish.date(from: now, remaining: tooFar, rate: 1) == nil)
        #expect(PlaybackFinish.date(from: now, remaining: tooFar, rate: 2) != nil)
    }

    @Test func theClockIsWrittenTheWayTheRegionWritesIt() {
        let finish = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(PlaybackFinish.label(finish, locale: Locale(identifier: "en_US")).contains("M"))
        let british = PlaybackFinish.label(finish, locale: Locale(identifier: "en_GB"))
        #expect(british.contains(":"))
        #expect(!british.contains("M"))
    }
}

#endif
