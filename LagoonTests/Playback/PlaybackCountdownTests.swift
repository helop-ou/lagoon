import Foundation
import Testing
@testable import Lagoon

/// The deadline a countdown's action and its visible fill share (HEL-178).
/// Progress is read from a monotonic clock rather than animated away from a
/// previous view value, because an overlay is created at the same moment its
/// countdown arms: there is no earlier value to animate from, which is why
/// both fills used to appear full for their whole run.
@Suite("Playback countdown")
struct PlaybackCountdownTests {
    @Test func progressRunsFromTheStartToTheDeadline() {
        let start = ContinuousClock.now
        let countdown = PlaybackCountdown(duration: .seconds(5), start: start)
        #expect(countdown.progress(at: start) == 0)
        #expect(abs(countdown.progress(at: start + .seconds(1)) - 0.2) < 0.001)
        #expect(abs(countdown.progress(at: start + .milliseconds(2_500)) - 0.5) < 0.001)
        #expect(countdown.progress(at: countdown.deadline) == 1)
    }

    /// The card outlives its own countdown while the successor is prepared
    /// (HEL-144), so progress past the deadline holds at full rather than
    /// wrapping or emptying underneath an accepted hand-off.
    @Test func progressClampsOutsideItsWindow() {
        let start = ContinuousClock.now
        let countdown = PlaybackCountdown(duration: .seconds(5), start: start)
        #expect(countdown.progress(at: start - .seconds(1)) == 0)
        #expect(countdown.progress(at: start + .seconds(60)) == 1)
    }

    /// An overlay mounted part-way through draws where the countdown already
    /// is. This is the whole point of sharing the deadline with the action.
    @Test func aLateObserverSeesElapsedProgress() {
        let countdown = PlaybackCountdown(duration: .seconds(5), start: .now - .seconds(3))
        #expect(abs(countdown.progress(at: .now) - 0.6) < 0.01)
    }

    /// Nothing to wait for reads as done, not as a divide by zero.
    @Test func aZeroDurationIsAlreadyDone() {
        let countdown = PlaybackCountdown(duration: .zero)
        #expect(countdown.progress(at: countdown.start) == 1)
    }
}
