import Foundation
import LagoonEngine
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

/// The watch against a bare engine, which never presents a frame.
@MainActor
@Suite("Playback start watch")
struct PlaybackStartWatchTests {
    /// Each sleep moves the clock one interval and lets the loop run on.
    @MainActor
    final class SteppingClock {
        var now: TimeInterval = 1_000
        var sleeps = 0
        var wakes = 0
        var onSleep: (() -> Void)?
        /// While set, a sleep waits instead of returning.
        var hold = false

        func sleep(_ duration: Duration) async throws {
            sleeps += 1
            while hold { try await Task.sleep(for: .milliseconds(1)) }
            now += Double(duration.components.seconds)
            onSleep?()
            await Task.yield()
            wakes += 1
        }
    }

    @MainActor
    final class Recorder {
        var stalls: [PlaybackStartWatch.Stall] = []
    }

    @Test func aStartThatNeverPresentsIsReportedOnceAsNoProgress() async throws {
        let clock = SteppingClock()
        let watch = PlaybackStartWatch(sleep: clock.sleep, uptime: { clock.now }, isAppActive: { true })
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        let recorder = Recorder()
        watch.begin(engine) { recorder.stalls.append($0) }

        try await Polling.untilMainActor(timeout: .seconds(5), pollInterval: .milliseconds(1)) {
            !recorder.stalls.isEmpty
        }
        let expected = PlaybackStartWatch.Stall(reason: .noProgress, seconds: 30, progress: PlaybackStartWatchdog.Progress())
        #expect(recorder.stalls == [expected])
        #expect(clock.sleeps == 15)
        // The verdict ends the watch.
        for _ in 0..<50 { await Task.yield() }
        #expect(recorder.stalls.count == 1)
        #expect(clock.sleeps == 15)
    }

    @Test func endingTheWatchStopsItBeforeAVerdict() async throws {
        let clock = SteppingClock()
        let watch = PlaybackStartWatch(sleep: clock.sleep, uptime: { clock.now }, isAppActive: { true })
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        let recorder = Recorder()
        clock.onSleep = { if clock.sleeps == 5 { watch.end() } }
        defer { clock.onSleep = nil }
        watch.begin(engine) { recorder.stalls.append($0) }

        try await Polling.untilMainActor(timeout: .seconds(5), pollInterval: .milliseconds(1)) {
            clock.sleeps >= 5
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(clock.sleeps == 5)
        #expect(recorder.stalls.isEmpty)
    }

    @Test func aGoneEngineEndsTheWatch() async throws {
        let clock = SteppingClock()
        clock.hold = true
        let watch = PlaybackStartWatch(sleep: clock.sleep, uptime: { clock.now }, isAppActive: { true })
        var engine: SampleBufferPlayerEngine? = SampleBufferPlayerEngine()
        weak var probe = engine
        let recorder = Recorder()
        watch.begin(try #require(engine)) { recorder.stalls.append($0) }
        try await Polling.untilMainActor(timeout: .seconds(5), pollInterval: .milliseconds(1)) {
            clock.sleeps == 1
        }

        engine?.shutdown()
        engine = nil
        try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(10)) {
            probe == nil
        }
        clock.hold = false
        try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(1)) {
            clock.wakes == 1
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(clock.sleeps == 1)
        #expect(recorder.stalls.isEmpty)
    }
}
