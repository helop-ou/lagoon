import Foundation
import Testing
@testable import Lagoon

/// Offline downloads: which resume position wins at start, and whether a
/// stopped position counts as played through.
@Suite("Download playback resume")
struct DownloadResumeStartSecondsTests {
    @Test func fallbackOverrideOutranksEverything() {
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: 42,
            startFromBeginning: true,
            localResumeTicks: Ticks.ticks(10),
            serverPositionTicks: Ticks.ticks(20)
        )
        #expect(seconds == 42)
    }

    @Test func localResumeWinsOverServerPosition() {
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: nil,
            startFromBeginning: false,
            localResumeTicks: Ticks.ticks(120),
            serverPositionTicks: Ticks.ticks(600)
        )
        #expect(seconds == 120)
    }

    @Test func startFromBeginningSkipsTheLocalResumeToo() {
        // Same as streaming: only a fallback retry outranks starting at 0.
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: nil,
            startFromBeginning: true,
            localResumeTicks: Ticks.ticks(120),
            serverPositionTicks: nil
        )
        #expect(seconds == 0)
    }

    @Test func serverPositionAppliesWithoutALocalDownload() {
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: nil,
            startFromBeginning: false,
            localResumeTicks: nil,
            serverPositionTicks: Ticks.ticks(300)
        )
        #expect(seconds == 300)
    }

    @Test func startFromBeginningSkipsTheServerPosition() {
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: nil,
            startFromBeginning: true,
            localResumeTicks: nil,
            serverPositionTicks: Ticks.ticks(300)
        )
        #expect(seconds == 0)
    }

    @Test func zeroServerPositionNeverResumes() {
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: nil,
            startFromBeginning: false,
            localResumeTicks: nil,
            serverPositionTicks: 0
        )
        #expect(seconds == 0)
    }

    @Test func nothingKnownStartsAtZero() {
        let seconds = PlaybackController.resumeStartSeconds(
            fallbackOverrideSeconds: nil,
            startFromBeginning: false,
            localResumeTicks: nil,
            serverPositionTicks: nil
        )
        #expect(seconds == 0)
    }
}

@Suite("Download playback played-through")
struct DownloadPlayedThroughTests {
    @Test func withinTheLastTwoPercentCountsAsPlayedThrough() {
        let runtime = Ticks.ticks(3_600)
        let position = Ticks.ticks(3_600 * 0.99)
        #expect(PlaybackReportingSession.isPlayedThrough(positionTicks: position, runtimeTicks: runtime))
    }

    @Test func exactlyAtTheThresholdCountsAsPlayedThrough() {
        let runtime = Ticks.ticks(1_000)
        let position = Ticks.ticks(980)
        #expect(PlaybackReportingSession.isPlayedThrough(positionTicks: position, runtimeTicks: runtime))
    }

    @Test func justBeforeTheThresholdDoesNotCount() {
        let runtime = Ticks.ticks(1_000)
        let position = Ticks.ticks(970)
        #expect(!PlaybackReportingSession.isPlayedThrough(positionTicks: position, runtimeTicks: runtime))
    }

    @Test func earlyPositionNeverCounts() {
        let runtime = Ticks.ticks(3_600)
        let position = Ticks.ticks(60)
        #expect(!PlaybackReportingSession.isPlayedThrough(positionTicks: position, runtimeTicks: runtime))
    }

    @Test func unknownRuntimeNeverCounts() {
        let position = Ticks.ticks(3_600)
        #expect(!PlaybackReportingSession.isPlayedThrough(positionTicks: position, runtimeTicks: nil))
    }

    @Test func zeroRuntimeNeverCounts() {
        let position = Ticks.ticks(0)
        #expect(!PlaybackReportingSession.isPlayedThrough(positionTicks: position, runtimeTicks: 0))
    }
}
