import Foundation

/// The action and its visible fill share one monotonic deadline. Progress
/// remains correct when an overlay first appears or returns from background.
nonisolated struct PlaybackCountdown: Equatable, Sendable {
    let start: ContinuousClock.Instant
    let duration: Duration

    init(duration: Duration, start: ContinuousClock.Instant = .now) {
        self.start = start
        self.duration = duration
    }

    var deadline: ContinuousClock.Instant { start + duration }

    func progress(at instant: ContinuousClock.Instant) -> Double {
        guard duration > .zero else { return 1 }
        let elapsed = start.duration(to: instant)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let durationSeconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return min(max(elapsedSeconds / durationSeconds, 0), 1)
    }
}
