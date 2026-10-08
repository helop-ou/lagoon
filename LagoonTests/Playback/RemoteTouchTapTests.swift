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

        // The representable refreshes this closure on state changes; the
        // recognizer must not keep the first render's handler.
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

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func anUnusableRateProjectsAtNormalSpeed(rate: Double) throws {
        let finish = try #require(PlaybackFinish.date(from: now, remaining: 600, rate: rate))
        #expect(finish.timeIntervalSince(now) == 600)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1.0])
    func anUnusableRemainderHasNoFinish(remaining: Double) {
        #expect(PlaybackFinish.date(from: now, remaining: remaining, rate: 1) == nil)
    }

    /// A live stream's duration cannot be projected, so the label shows time left.
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
