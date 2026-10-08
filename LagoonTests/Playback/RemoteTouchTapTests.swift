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

    @Test func aRefreshHandsTheTouchTapTheLatestHandler() {
        var taps: [String] = []
        let controller = MenuGateHostingController(rootView: EmptyView())
        MenuPressGate(onMenu: {}, onRemoteTouchTap: { taps.append("first") }) { EmptyView() }
            .applyHandlers(to: controller)
        controller.remoteTouchTapRecognized()

        // A state change renders the representable again with fresh closures;
        // the recognizer must not keep the first render's handler.
        MenuPressGate(onMenu: {}, onRemoteTouchTap: { taps.append("second") }) { EmptyView() }
            .applyHandlers(to: controller)
        controller.remoteTouchTapRecognized()
        #expect(taps == ["first", "second"])
    }

    /// Select is judged when the press begins, so a panel button that closes
    /// the panel under the press does not also toggle playback, or the
    /// other way round.
    @Test func selectIsDecidedWhenThePressBegins() {
        let inputs = GateInputs()
        let controller = inputs.controller()
        let select: Set<UIPress> = [FakePress(.select)]

        controller.pressesBegan(select, with: nil)
        inputs.canTakeSelect = false
        controller.pressesEnded(select, with: nil)
        #expect(inputs.log == ["select"])

        controller.pressesBegan(select, with: nil)
        inputs.canTakeSelect = true
        controller.pressesEnded(select, with: nil)
        #expect(inputs.log == ["select"])
    }

    @Test func aCancelledSelectDoesNothing() {
        let inputs = GateInputs()
        let controller = inputs.controller()
        let select: Set<UIPress> = [FakePress(.select)]
        controller.pressesBegan(select, with: nil)
        controller.pressesCancelled(select, with: nil)
        controller.pressesEnded(select, with: nil)
        #expect(inputs.log.isEmpty)
    }

    /// Menu is the gate's own decision: open panel or exit. It never reaches
    /// Select, and Select never reaches the touch-surface tap.
    @Test func eachInputKeepsItsOwnPath() {
        let inputs = GateInputs()
        let controller = inputs.controller()
        let menu: Set<UIPress> = [FakePress(.menu)]
        let select: Set<UIPress> = [FakePress(.select)]
        controller.pressesBegan(menu, with: nil)
        controller.pressesEnded(menu, with: nil)
        #expect(inputs.log == ["menu"])
        controller.pressesBegan(select, with: nil)
        controller.pressesEnded(select, with: nil)
        #expect(inputs.log == ["menu", "select"])
        controller.remoteTouchTapRecognized()
        #expect(inputs.log == ["menu", "select", "tap"])
    }
}

@Suite("Select arming")
struct SelectArmingTests {
    @Test func aPressArmedAtItsStartFiresOnce() {
        var arming = SelectArming()
        arming.began(canTake: true)
        let first = arming.ended()
        let second = arming.ended()
        #expect(first)
        #expect(!second)
    }

    @Test func aPressRefusedAtItsStartNeverFires() {
        var arming = SelectArming()
        arming.began(canTake: false)
        let fired = arming.ended()
        #expect(!fired)
    }

    @Test func aCancelledPressNeverFires() {
        var arming = SelectArming()
        arming.began(canTake: true)
        arming.cancelled()
        let fired = arming.ended()
        #expect(!fired)
    }
}

/// What reached each of the gate's handlers, in order.
@MainActor
private final class GateInputs {
    var canTakeSelect = true
    private(set) var log: [String] = []

    func controller() -> MenuGateHostingController<EmptyView> {
        let controller = MenuGateHostingController(rootView: EmptyView())
        MenuPressGate(
            onMenu: { self.log.append("menu") },
            canTakeSelect: { self.canTakeSelect },
            onSelect: { self.log.append("select") },
            onRemoteTouchTap: { self.log.append("tap") }
        ) { EmptyView() }
            .applyHandlers(to: controller)
        return controller
    }
}

/// A press UIKit never sent, so the gate's overrides can be driven directly.
private final class FakePress: UIPress {
    private let pressType: UIPress.PressType

    init(_ type: UIPress.PressType) {
        pressType = type
        super.init()
    }

    override var type: UIPress.PressType { pressType }
    override var key: UIKey? { nil }
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
