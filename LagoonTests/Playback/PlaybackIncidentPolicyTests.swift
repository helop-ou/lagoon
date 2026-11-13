import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

@Suite("Playback freeze detector")
struct PlaybackFreezeDetectorTests {
    static func playing(position: Double, sinceSeek: Double? = nil) -> PlaybackFreezeDetector.Sample {
        PlaybackFreezeDetector.Sample(
            position: position, isPaused: false, isBuffering: false, rate: 1,
            duration: 3_600, isFinished: false, isAppActive: true, secondsSinceSeek: sinceSeek
        )
    }

    @Test func aStuckPlayheadIsReportedOnceAfterTheThreshold() {
        var detector = PlaybackFreezeDetector()
        #expect(detector.observe(Self.playing(position: 10), at: 0) == .idle)
        #expect(detector.observe(Self.playing(position: 12), at: 2) == .idle)
        #expect(detector.observe(Self.playing(position: 12), at: 4) == .watching(seconds: 2))
        #expect(detector.observe(Self.playing(position: 12.02), at: 8) == .watching(seconds: 6))
        #expect(detector.observe(Self.playing(position: 12), at: 10) == .frozen(seconds: 8, kind: .playhead))
        // Reported once. A still-stuck playhead keeps watching.
        #expect(detector.observe(Self.playing(position: 12), at: 12) == .watching(seconds: 10))
        // Progress resets. A second freeze reports again.
        #expect(detector.observe(Self.playing(position: 13), at: 14) == .idle)
        #expect(detector.observe(Self.playing(position: 13), at: 23) == .frozen(seconds: 9, kind: .playhead))
    }

    @Test func aRunningClockOverAStuckPictureIsAFreezeToo() {
        var detector = PlaybackFreezeDetector()
        var sample = Self.playing(position: 10)
        sample.framesPresented = 240
        #expect(detector.observe(sample, at: 0) == .idle)
        sample.position = 12
        sample.framesPresented = 288
        #expect(detector.observe(sample, at: 2) == .idle)
        // The clock keeps moving, the frame count does not.
        sample.position = 14
        #expect(detector.observe(sample, at: 4) == .watching(seconds: 2))
        sample.position = 20
        #expect(detector.observe(sample, at: 10) == .frozen(seconds: 8, kind: .picture))
        sample.position = 22
        #expect(detector.observe(sample, at: 12) == .watching(seconds: 10))
        // Frames resume: reset.
        sample.position = 24
        sample.framesPresented = 300
        #expect(detector.observe(sample, at: 14) == .idle)
        // No metric yet means no picture verdict at all.
        var blind = PlaybackFreezeDetector()
        var noMetric = Self.playing(position: 1)
        _ = blind.observe(noMetric, at: 0)
        noMetric.position = 30
        #expect(blind.observe(noMetric, at: 29) == .idle)
    }

    @Test func normalReasonsForNoProgressAreNotFreezes() {
        var detector = PlaybackFreezeDetector()
        var sample = Self.playing(position: 12)
        _ = detector.observe(sample, at: 0)
        sample.isPaused = true
        #expect(detector.observe(sample, at: 20) == .idle)
        sample.isPaused = false
        sample.isBuffering = true
        #expect(detector.observe(sample, at: 40) == .idle)
        sample.isBuffering = false
        sample.rate = 0
        #expect(detector.observe(sample, at: 60) == .idle)
        sample.rate = 1
        sample.secondsSinceSeek = 1
        #expect(detector.observe(sample, at: 80) == .idle)
        sample.secondsSinceSeek = nil
        sample.position = 3_599
        #expect(detector.observe(sample, at: 100) == .idle)
        sample.position = 12
        sample.isAppActive = false
        #expect(detector.observe(sample, at: 120) == .idle)
        // Back to playing: the clock starts from here, not from t=0.
        sample.isAppActive = true
        #expect(detector.observe(sample, at: 130) == .idle)
        #expect(detector.observe(sample, at: 135) == .watching(seconds: 5))
    }

    /// Paused by an interruption that is still open, unless said otherwise.
    static func held(interrupted: Bool = true, active: Bool = true) -> PlaybackFreezeDetector.Sample {
        var sample = playing(position: 12)
        sample.isPaused = true
        sample.isInterrupted = interrupted
        sample.isAppActive = active
        return sample
    }

    /// An interruption pauses the title until the system says to resume. One
    /// the system never ends leaves it stopped with nobody having asked.
    @Test func aTitleAnInterruptionPausedAndNeverGaveBackIsReportedOnce() {
        var detector = PlaybackFreezeDetector()
        _ = detector.observe(Self.playing(position: 10), at: 0)
        #expect(detector.observe(Self.held(), at: 2) == .watching(seconds: 0))
        #expect(detector.observe(Self.held(), at: 16) == .watching(seconds: 14))
        #expect(detector.observe(Self.held(), at: 18) == .frozen(seconds: 16, kind: .interrupted))
        // Reported once, however long it lasts.
        #expect(detector.observe(Self.held(), at: 60) == .watching(seconds: 58))
        // Playing again resets it, and the next one reports again.
        #expect(detector.observe(Self.playing(position: 13), at: 62) == .idle)
        #expect(detector.observe(Self.held(), at: 64) == .watching(seconds: 0))
        #expect(detector.observe(Self.held(), at: 80) == .frozen(seconds: 16, kind: .interrupted))
    }

    /// The system may end an interruption without saying to resume. The
    /// title is as stopped as before.
    @Test func anInterruptionThatEndsWithoutAResumeStillCounts() {
        var detector = PlaybackFreezeDetector()
        #expect(detector.observe(Self.held(), at: 0) == .watching(seconds: 0))
        #expect(detector.observe(Self.held(interrupted: false), at: 15) == .frozen(seconds: 15, kind: .interrupted))
    }

    /// The session only calls a title interrupted when the interruption is
    /// what paused it, so a pause the viewer made never counts.
    @Test func aPauseTheViewerMadeIsNotHeldByAnInterruption() {
        var detector = PlaybackFreezeDetector()
        #expect(detector.observe(Self.held(interrupted: false), at: 0) == .idle)
        #expect(detector.observe(Self.held(interrupted: false), at: 60) == .idle)
        // Nor one made after the viewer started it again.
        #expect(detector.observe(Self.held(), at: 62) == .watching(seconds: 0))
        #expect(detector.observe(Self.playing(position: 14), at: 64) == .idle)
        #expect(detector.observe(Self.held(interrupted: false), at: 66) == .idle)
        #expect(detector.observe(Self.held(interrupted: false), at: 120) == .idle)
    }

    /// A call takes the app out of the front. Only time in front counts.
    @Test func timeAwayFromTheAppIsNotCountedAgainstAnInterruption() {
        var detector = PlaybackFreezeDetector()
        #expect(detector.observe(Self.held(), at: 0) == .watching(seconds: 0))
        #expect(detector.observe(Self.held(active: false), at: 10) == .idle)
        #expect(detector.observe(Self.held(active: false), at: 300) == .idle)
        #expect(detector.observe(Self.held(), at: 302) == .watching(seconds: 0))
        #expect(detector.observe(Self.held(), at: 317) == .frozen(seconds: 15, kind: .interrupted))
    }
}

@Suite("Playback degradation policy")
struct PlaybackDegradationPolicyTests {
    @Test func healthyAndShortSessionsAreSilent() {
        var counters = PlaybackDegradationPolicy.Counters(playedSeconds: 7_200, droppedFrames: 20, totalFrames: 170_000)
        #expect(PlaybackDegradationPolicy.reasons(for: counters).isEmpty)
        counters = PlaybackDegradationPolicy.Counters(playedSeconds: 10, droppedFrames: 200, totalFrames: 240, stalls: 5)
        #expect(PlaybackDegradationPolicy.reasons(for: counters).isEmpty)
    }

    @Test func thresholdsProduceSortedReasons() {
        let counters = PlaybackDegradationPolicy.Counters(
            playedSeconds: 600, droppedFrames: 900, totalFrames: 14_400,
            stalls: 3, reprimes: 1, audioStarvation: 5, frozen: 1, rendererRecoveries: 2
        )
        #expect(PlaybackDegradationPolicy.reasons(for: counters) == ["audioStarvation", "droppedFrames", "reprimes", "stalls"])
        // Drops need both an absolute floor and a ratio.
        let fewDrops = PlaybackDegradationPolicy.Counters(playedSeconds: 600, droppedFrames: 59, totalFrames: 100)
        #expect(PlaybackDegradationPolicy.reasons(for: fewDrops).isEmpty)
        let lowRatio = PlaybackDegradationPolicy.Counters(playedSeconds: 600, droppedFrames: 100, totalFrames: 100_000)
        #expect(PlaybackDegradationPolicy.reasons(for: lowRatio).isEmpty)
    }

    @Test func optingOutMakesSessionWideDegradationCountersIneligible() {
        // These totals may include the opt-out gap, which sampled time does not.
        let counters = PlaybackDegradationPolicy.Counters(
            playedSeconds: 60, droppedFrames: 100, totalFrames: 10_000,
            stalls: 3, reprimes: 1, audioStarvation: 5
        )
        #expect(!PlaybackDegradationPolicy.reasons(for: counters).isEmpty)
        #expect(PlaybackDegradationPolicy.reasons(for: counters, sampledWholeAttempt: false).isEmpty)
    }
}
