import Foundation
@testable import Lagoon
import Testing

/// On an Apple TV a title started about half a second into a three second
/// display mode switch, and its first seconds played on a black panel.
struct DisplaySwitchWaitTests {
    private typealias State = DisplaySwitchWait.State

    @Test func nothingAskedOfTheDisplayIsNothingToWaitFor() {
        #expect(DisplaySwitchWait.remaining(State(), now: 100) == nil)
    }

    @Test func aSwitchMayStillBeginShortlyAfterTheCriteriaChange() throws {
        let state = State(appliedAt: 100)
        let left = try #require(DisplaySwitchWait.remaining(state, now: 100.1))
        #expect(abs(left - 0.2) < 0.000_001)
        // The display was already in that mode.
        #expect(DisplaySwitchWait.remaining(state, now: 100.3) == nil)
        #expect(DisplaySwitchWait.remaining(state, now: 250) == nil)
    }

    @Test func aSwitchThatBeganIsWaitedForUntilItEnds() throws {
        var state = State(appliedAt: 100, switchStartedAt: 100.02, switchInProgress: true)
        // Long past the grace: the switch itself is what is waited for.
        let left = try #require(DisplaySwitchWait.remaining(state, now: 102))
        #expect(abs(left - 2.02) < 0.000_001)
        state.switchInProgress = false
        #expect(DisplaySwitchWait.remaining(state, now: 102) == nil)
    }

    @Test func aSwitchThatNeverAnnouncesItsEndIsGivenUpOn() {
        let state = State(appliedAt: 100, switchStartedAt: 100, switchInProgress: true)
        #expect(DisplaySwitchWait.remaining(state, now: 103.9) != nil)
        #expect(DisplaySwitchWait.remaining(state, now: 104) == nil)
    }

    @MainActor
    @Test func settlingReturnsAsSoonAsTheSwitchEnds() async {
        var state = State(appliedAt: 0)
        var now = 0.0
        await DisplaySwitchWait.settle(state: { state }, now: { now }, sleep: { seconds in
            now += seconds
            if now >= 0.02, state.switchStartedAt == nil {
                state.switchStartedAt = now
                state.switchInProgress = true
            }
            if now >= 2.95 { state.switchInProgress = false }
        })
        #expect(now >= 2.95 && now < 3.05, "waited \(now) s")
    }

    @MainActor
    @Test func settlingWithoutASwitchCostsOnlyTheGrace() async {
        var now = 10.0
        var sleeps = 0
        await DisplaySwitchWait.settle(state: { State(appliedAt: 10) }, now: { now }, sleep: { seconds in
            now += seconds
            sleeps += 1
        })
        #expect(abs(now - 10.3) < 0.000_001, "waited until \(now)")
        #expect(sleeps >= 6)
    }

    @MainActor
    @Test func settlingGivesUpOnASwitchThatNeverEnds() async {
        var now = 0.0
        let stuck = State(appliedAt: 0, switchStartedAt: 0, switchInProgress: true)
        await DisplaySwitchWait.settle(state: { stuck }, now: { now }, sleep: { now += $0 })
        #expect(abs(now - 4) < 0.000_001, "waited until \(now)")
    }
}
