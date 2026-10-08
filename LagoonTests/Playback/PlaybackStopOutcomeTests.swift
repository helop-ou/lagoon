import Testing
@testable import Lagoon

/// How the diagnostics history names the end of an attempt. Several can be
/// true at once; the first that applies wins.
@Suite("Playback stop outcome")
struct PlaybackStopOutcomeTests {
    private func outcome(
        failed: Bool = false,
        finished: Bool = false,
        handingOff: Bool = false,
        fallingBack: Bool = false,
        changingQuality: Bool = false
    ) -> String {
        PlaybackController.stopOutcome(
            failed: failed,
            finished: finished,
            handingOff: handingOff,
            fallingBack: fallingBack,
            changingQuality: changingQuality
        )
    }

    @Test func aPlainCloseIsStopped() {
        #expect(outcome() == "stopped")
    }

    @Test func eachEndOutranksTheOnesAfterIt() {
        #expect(outcome(failed: true, finished: true, handingOff: true, fallingBack: true, changingQuality: true)
            == "failed")
        #expect(outcome(finished: true, handingOff: true, fallingBack: true, changingQuality: true) == "finished")
        #expect(outcome(handingOff: true, fallingBack: true, changingQuality: true) == "handoff")
        #expect(outcome(fallingBack: true, changingQuality: true) == "fallback")
        #expect(outcome(changingQuality: true) == "quality")
    }
}
