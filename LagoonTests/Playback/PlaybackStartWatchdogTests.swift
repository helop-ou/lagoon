import Foundation
import Testing
@testable import Lagoon

@Suite("Playback start watchdog")
struct PlaybackStartWatchdogTests {
    static func progress(bytes: Int64 = 0, queued: Int = 0) -> PlaybackStartWatchdog.Progress {
        PlaybackStartWatchdog.Progress(bytes: bytes, videoIntake: 0, videoQueued: queued, audioQueued: 0)
    }

    @Test func aStartThatStopsMovingIsAbandonedAfterTheIdleLimit() {
        var watchdog = PlaybackStartWatchdog()
        #expect(watchdog.observe(Self.progress(), isAppActive: true, at: 100) == .waiting)
        #expect(watchdog.observe(Self.progress(bytes: 4_096), isAppActive: true, at: 104) == .waiting)
        // Nothing more arrives, as when every HLS segment request times out.
        #expect(watchdog.observe(Self.progress(bytes: 4_096), isAppActive: true, at: 133) == .waiting)
        #expect(watchdog.observe(Self.progress(bytes: 4_096), isAppActive: true, at: 134) == .stalled(.noProgress, seconds: 34))
    }

    @Test func anyCounterMovingCountsAsProgress() {
        var watchdog = PlaybackStartWatchdog()
        _ = watchdog.observe(Self.progress(), isAppActive: true, at: 0)
        // No cache in front of HLS, so only the queues move.
        #expect(watchdog.observe(Self.progress(queued: 3), isAppActive: true, at: 29) == .waiting)
        #expect(watchdog.observe(Self.progress(queued: 3), isAppActive: true, at: 58) == .waiting)
        #expect(watchdog.observe(Self.progress(queued: 2), isAppActive: true, at: 87) == .waiting)
        #expect(watchdog.observe(Self.progress(queued: 2), isAppActive: true, at: 117) == .stalled(.noProgress, seconds: 117))
    }

    @Test func aStartThatKeepsCreepingIsAbandonedAfterTheOverallLimit() {
        var watchdog = PlaybackStartWatchdog()
        var bytes: Int64 = 0
        var now: TimeInterval = 0
        while now < PlaybackStartWatchdog.overallLimit {
            #expect(watchdog.observe(Self.progress(bytes: bytes), isAppActive: true, at: now) == .waiting)
            bytes += 512
            now += 10
        }
        #expect(watchdog.observe(Self.progress(bytes: bytes), isAppActive: true, at: now) == .stalled(.tooSlow, seconds: 120))
    }

    @Test func timeAwayFromTheAppDoesNotCount() {
        var watchdog = PlaybackStartWatchdog()
        _ = watchdog.observe(Self.progress(), isAppActive: true, at: 0)
        #expect(watchdog.observe(Self.progress(), isAppActive: false, at: 25) == .waiting)
        #expect(watchdog.observe(Self.progress(), isAppActive: false, at: 300) == .waiting)
        // Back in the app: the clocks start again here.
        #expect(watchdog.observe(Self.progress(), isAppActive: true, at: 310) == .waiting)
        #expect(watchdog.observe(Self.progress(), isAppActive: true, at: 339) == .waiting)
        #expect(watchdog.observe(Self.progress(), isAppActive: true, at: 340) == .stalled(.noProgress, seconds: 30))
    }
}
