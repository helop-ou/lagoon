import Foundation

/// The measurement discipline of HEL-64, encoded so nobody has to remember
/// it: a frame-loss number is only comparable when it comes from the same
/// scene over the same media-time window, untouched. Both of this ticket's
/// false positives came from violating that.
///
/// Armed by Settings → Debug → Frame-loss bench: after every playback
/// start or seek the bench warms up for `warmupSeconds` of *media time*,
/// measures for `windowSeconds`, then freezes its result (HUD line +
/// `Bench Result` signpost). Touching the transport re-arms it from the
/// new position, so "seek to the scene, hands off, read the number" is the
/// whole protocol — identical in the simulator and on real hardware.
///
/// Windows are keyed on playback position, not wall time: screenshots and
/// stalls stretch wall time but not media time, so the denominator stays
/// honest. Stalls during the window are reported, not discarded — a stall
/// is a finding.
nonisolated struct FrameLossBench: Equatable {
    struct Sample: Equatable {
        var position: Double
        var totalFrames: Int
        var droppedFrames: Int
        var corruptedFrames: Int
        var stalls: Int
        var audioGaps: Int
        var videoQueueDepth: Int
        var optimizedFrames = 0
        var accumulatedDelay = 0.0
    }

    struct Result: Equatable {
        var startPosition: Double
        var windowSeconds: Double
        var frames: Int
        var dropped: Int
        var corrupted: Int
        var stalls: Int
        var audioGaps: Int
        var minVideoQueue: Int
        /// Frames that took the direct-display path inside the window —
        /// compare against `frames` to see whether video is being
        /// composited with UI (HEL-64).
        var optimizedFrames = 0
        /// Seconds of accumulated display lateness inside the window.
        var accumulatedDelay = 0.0

        var lossPercent: Double {
            frames > 0 ? Double(dropped) / Double(frames) * 100 : 0
        }
    }

    enum Phase: Equatable {
        case warming(measureFrom: Double)
        case measuring(since: Double)
        case done(Result)
    }

    let warmupSeconds: Double
    let windowSeconds: Double
    private(set) var phase: Phase
    private var start: Sample?
    private var minVideoQueue = Int.max

    init(at position: Double, warmupSeconds: Double = 10, windowSeconds: Double = 60) {
        self.warmupSeconds = warmupSeconds
        self.windowSeconds = windowSeconds
        phase = .warming(measureFrom: position + warmupSeconds)
    }

    /// The transport was touched (seek, pause) — the running window is no
    /// longer a controlled measurement. Start over from the new position.
    mutating func rearm(at position: Double) {
        phase = .warming(measureFrom: position + warmupSeconds)
        start = nil
        minVideoQueue = .max
    }

    /// Feed one metrics snapshot; returns the result exactly once, on the
    /// sample that completes the window.
    mutating func record(_ sample: Sample) -> Result? {
        switch phase {
        case .done:
            return nil
        case .warming(let measureFrom):
            guard sample.position >= measureFrom else { return nil }
            start = sample
            minVideoQueue = sample.videoQueueDepth
            phase = .measuring(since: sample.position)
            return nil
        case .measuring:
            guard let start else { return nil }
            minVideoQueue = min(minVideoQueue, sample.videoQueueDepth)
            guard sample.position - start.position >= windowSeconds else { return nil }
            let result = Result(
                startPosition: start.position,
                windowSeconds: sample.position - start.position,
                frames: sample.totalFrames - start.totalFrames,
                dropped: sample.droppedFrames - start.droppedFrames,
                corrupted: sample.corruptedFrames - start.corruptedFrames,
                stalls: sample.stalls - start.stalls,
                audioGaps: sample.audioGaps - start.audioGaps,
                minVideoQueue: minVideoQueue,
                optimizedFrames: sample.optimizedFrames - start.optimizedFrames,
                accumulatedDelay: sample.accumulatedDelay - start.accumulatedDelay
            )
            phase = .done(result)
            return result
        }
    }
}
