import Foundation
import Testing
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
        // Reported once; a still-stuck playhead keeps watching.
        #expect(detector.observe(Self.playing(position: 12), at: 12) == .watching(seconds: 10))
        // Progress resets; a second freeze reports again.
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
        // These totals could all have accumulated during the opt-out gap.
        // Comparing them with only the sampled playing time is misleading.
        let counters = PlaybackDegradationPolicy.Counters(
            playedSeconds: 60, droppedFrames: 100, totalFrames: 10_000,
            stalls: 3, reprimes: 1, audioStarvation: 5
        )
        #expect(!PlaybackDegradationPolicy.reasons(for: counters).isEmpty)
        #expect(PlaybackDegradationPolicy.reasons(for: counters, sampledWholeAttempt: false).isEmpty)
    }
}

@Suite("Playback failure detail")
struct PlaybackFailureDetailTests {
    @Test func onlyDomainAndCodeSurviveAnError() {
        let error = NSError(domain: "NSURLErrorDomain", code: -1200, userInfo: [
            NSLocalizedDescriptionKey: "An SSL error has occurred and a secure connection to https://fixture.example.eu cannot be made.",
            NSURLErrorFailingURLErrorKey: URL(string: "https://fixture.example.eu/Videos/1/stream?api_key=secret") as Any,
        ])
        let detail = PlaybackFailureDetail(stage: .open, error: error)
        #expect(detail.fields == ["stage": .string("open"), "errorDomain": .string("NSURLErrorDomain"), "errorCode": .int(-1200)])
        #expect(detail.fingerprint == ["open", "NSURLErrorDomain", "-1200"])
        let demux = DemuxError.openFailed("moov atom not found", code: -1094995529).diagnosticDetail
        #expect(demux.stage == .open)
        #expect(demux.code == -1094995529)
        #expect(DemuxError.seekFailed("demuxer not open").diagnosticDetail.code == nil)
    }
}
