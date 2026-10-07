import CoreMedia
import LagoonEngine

// What a SyncPlay driver calls. Separate from the viewer's controls, which
// the driver turns into group requests, so this path does not recurse. The
// driver never holds the engine.
extension PlaybackController {
    /// Start so the current position is on screen exactly at `hostTime`.
    func playGroup(atHostTime hostTime: CMTime) {
        engine?.play(atHostTime: hostTime)
    }

    func pauseGroup() {
        engine?.pause()
    }

    func seekGroup(to seconds: Double) {
        engine?.seek(to: seconds)
    }

    /// A drift nudge on top of the viewer's speed. 1 is no correction.
    func setCorrectionRate(_ multiplier: Double) {
        engine?.setCorrectionRate(multiplier)
    }

    /// The synchronizer's media clock, 0 with no engine. For the driver,
    /// never a view: it is tick-rate state the player root must not read.
    var clockPosition: Double { engine?.clockPosition ?? 0 }

    /// The clock is advancing (a group report's `IsPlaying`). Not simply
    /// the inverse of paused: a buffering engine is neither.
    var isClockRunning: Bool {
        guard let engine else { return false }
        return !engine.isPaused && !engine.isBuffering
    }
}
