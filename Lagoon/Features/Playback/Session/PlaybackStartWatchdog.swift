import Foundation

/// Gives up on a start that has stopped getting anywhere.
///
/// Until the first frame the engine has no stall detection, so a stream that
/// stops sending keeps the spinner up for as long as the viewer waits. Bytes
/// read and packets queued count as progress, so a slow start that is still
/// moving is left alone. Pure so the limits can be pinned.
nonisolated struct PlaybackStartWatchdog: Equatable, Sendable {
    struct Progress: Equatable, Sendable {
        /// Bytes the cache has served. Zero without one, as for HLS.
        var bytes: Int64 = 0
        var videoIntake = 0
        var videoQueued = 0
        var audioQueued = 0
    }

    enum Reason: String, Equatable, Sendable {
        /// Nothing moved for `idleLimit`.
        case noProgress
        /// Still no first frame after `overallLimit`.
        case tooSlow
    }

    enum Verdict: Equatable, Sendable {
        case waiting
        case stalled(Reason, seconds: Double)
    }

    static let idleLimit: Double = 30
    static let overallLimit: Double = 120

    private(set) var startedAt: TimeInterval?
    private(set) var lastProgress: Progress?
    private(set) var lastProgressAt: TimeInterval?

    /// Time away from the app does not count: both clocks restart on return.
    mutating func observe(_ progress: Progress, isAppActive: Bool, at now: TimeInterval) -> Verdict {
        guard isAppActive else {
            self = PlaybackStartWatchdog()
            return .waiting
        }
        guard let startedAt, let lastProgressAt else {
            startedAt = now
            lastProgress = progress
            lastProgressAt = now
            return .waiting
        }
        var idleSince = lastProgressAt
        if progress != lastProgress {
            lastProgress = progress
            self.lastProgressAt = now
            idleSince = now
        }
        let waited = now - startedAt
        if now - idleSince >= Self.idleLimit {
            return .stalled(.noProgress, seconds: waited)
        }
        if waited >= Self.overallLimit {
            return .stalled(.tooSlow, seconds: waited)
        }
        return .waiting
    }
}
