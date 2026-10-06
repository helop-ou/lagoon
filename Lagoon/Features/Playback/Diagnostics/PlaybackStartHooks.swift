import Foundation
import LagoonEngine

/// The launch flags that bend a playback start for the frame-loss bench and
/// the UI regression journeys, read in one place so the start sequence reads
/// as a viewer's start.
///
/// The bench hooks are not compiled out: the bench measures Release builds.
struct PlaybackStartHooks {
    #if DEBUG
    /// `debug.regressionStartNearEnd` applies to the fixture episode only;
    /// applied to the successor, the hand-off test exits too early.
    private var didApplyNearEnd = false
    #endif

    /// The rung a new item starts on. A regression run can force one, so HLS
    /// cases run on a server that would direct-play everything. Raw value
    /// `remux` or `transcode`.
    func initialDelivery() -> PlaybackDelivery {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.playerRegression"),
           let forced = UserDefaults.standard.string(forKey: "debug.regressionInitialDelivery"),
           let rung = PlaybackDelivery(rawValue: forced) {
            return rung
        }
        #endif
        return .negotiated
    }

    /// The bench's pinned start, then the regression near-end start.
    /// Applied after the attempt is recorded, which keeps the real resume
    /// position.
    mutating func pinnedStart(_ seconds: Double, runtimeTicks: Int64?) -> Double {
        var seconds = seconds
        if UserDefaults.standard.bool(forKey: "debug.frameLossBench") {
            let pinnedStart = UserDefaults.standard.double(forKey: "debug.benchStartSeconds")
            if pinnedStart > 0 {
                seconds = pinnedStart
            }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.regressionStartNearEnd"),
           !didApplyNearEnd,
           let runtimeTicks {
            didApplyNearEnd = true
            seconds = max(Ticks.seconds(runtimeTicks) - 45, 0)
        }
        #endif
        return seconds
    }

    /// A regression run can start inside the first skippable segment.
    func skippableStart(_ seconds: Double, segments: [MediaSegment]) -> Double {
        guard UserDefaults.standard.bool(forKey: "debug.playerRegression"),
              UserDefaults.standard.bool(forKey: "debug.regressionStartAtFirstSkippable"),
              let segment = segments.first(where: { $0.kind.isSkippable }) else { return seconds }
        return segment.start + min(max((segment.end - segment.start) / 4, 0.1), 1)
    }

    /// The bench's subtitle language, which outranks every selection rule.
    var benchSubtitleLanguage: String? {
        UserDefaults.standard.string(forKey: "debug.benchSubtitleLanguage")
    }

    /// Widens the window where dismissal races startup, for a UI test.
    func delayStartup() async throws {
        #if DEBUG
        let delay = UserDefaults.standard.double(forKey: "debug.regressionPlaybackStartDelaySeconds")
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        #endif
    }
}
