import Foundation

/// The proactive fill scheduler's decisions, kept free of the engine, the
/// cache and the clock so a unit test can walk it through a session
/// (HEL-160). `PlaybackController.startBufferFill` owns the loop; this owns
/// what the loop does next.
///
/// The old loop slept `min(max(requestSeconds, 0.125) * 4, 8)` seconds after
/// every 1 MiB chunk while playing, a fixed ~20% duty cycle that capped
/// read-ahead near 2 MiB/s however fast the link was. Now the cushion decides:
/// below `targetAheadSeconds` of cached media the next chunk follows the last
/// one after a yield proportional to the request it just made, so a fast link
/// fills fast and a slow one still leaves room for foreground reads; above
/// the target the old pacing returns, since there is no hurry. A failed
/// fetch backs off and is retried; only cancellation, a complete file, or
/// an exhausted whole-file cap end the loop.
nonisolated struct PlaybackFillPolicy: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case fetch
        case wait(TimeInterval)
        case stop
    }

    /// What the scheduler sees between fetches. `aheadSeconds` is nil when
    /// the title's duration or length is unknown; the policy then treats
    /// the cushion as short, because starving a title it cannot measure is
    /// the worse failure.
    struct Snapshot: Equatable, Sendable {
        var isPaused = false
        var isBuffering = false
        var newStall = false
        var aheadSeconds: Double?
        var isWindowed = false
        var bufferedFraction: Double?
    }

    /// Fill only begins after the player has presented its initial cushion.
    static let warmupSeconds: TimeInterval = 3
    /// A renderer stall means the foreground needs every byte it can get.
    static let stallCooldownSeconds: TimeInterval = 20
    /// A full window waits for the playhead to make room.
    static let idlePollSeconds: TimeInterval = 2
    /// Cached media ahead of the playhead the scheduler tries to keep.
    static let targetAheadSeconds: Double = 120
    /// Below the target: yield this fraction of the last request's own time
    /// between chunks, so foreground requests can slot in on a saturated
    /// link without the fill ever idling on a fast one.
    static let hurriedYieldFraction: Double = 0.5
    static let hurriedYieldCapSeconds: TimeInterval = 0.5
    /// Above the target: the pre-HEL-160 pacing, roughly a 20% duty cycle.
    static let relaxedPacingMultiplier: Double = 4
    static let relaxedPacingCapSeconds: TimeInterval = 8
    static let minimumMeasuredRequestSeconds: TimeInterval = 0.125
    static let failureBackoffBaseSeconds: TimeInterval = 1
    static let failureBackoffCapSeconds: TimeInterval = 30

    private(set) var consecutiveFailures = 0

    /// Before a fetch: a title that fits under the cap finishes and the loop
    /// ends; a stall or buffering renderer gets the link to itself for a
    /// while.
    func beforeFetch(_ snapshot: Snapshot) -> Decision {
        if snapshot.bufferedFraction == 1, !snapshot.isWindowed {
            return .stop
        }
        if snapshot.isBuffering || snapshot.newStall {
            return .wait(Self.stallCooldownSeconds)
        }
        return .fetch
    }

    /// After a fetch: pace, poll, back off, or stop, by what the fetch did.
    mutating func afterFetch(_ outcome: PlaybackPrefetchOutcome, _ snapshot: Snapshot) -> Decision {
        switch outcome {
        case .cancelled:
            return .stop
        case .failed:
            consecutiveFailures += 1
            let exponent = Double(min(consecutiveFailures - 1, 10))
            let backoff = Self.failureBackoffBaseSeconds * pow(2, exponent)
            return .wait(min(backoff, Self.failureBackoffCapSeconds))
        case .exhausted:
            consecutiveFailures = 0
            // A windowed cache's read-ahead is full: wait for the playhead to
            // make room rather than give up on the rest of the movie. A
            // whole-file cache with nothing left is done.
            return snapshot.isWindowed ? .wait(Self.idlePollSeconds) : .stop
        case .fetched(_, let seconds):
            consecutiveFailures = 0
            if snapshot.isPaused {
                // No foreground demux request is consuming: full speed.
                return .fetch
            }
            let measured = max(seconds, Self.minimumMeasuredRequestSeconds)
            if let ahead = snapshot.aheadSeconds, ahead >= Self.targetAheadSeconds {
                return .wait(min(measured * Self.relaxedPacingMultiplier, Self.relaxedPacingCapSeconds))
            }
            return .wait(min(seconds * Self.hurriedYieldFraction, Self.hurriedYieldCapSeconds))
        }
    }

    /// Seconds of media a byte cushion represents, assuming the title's
    /// average bitrate. Nil when either side is unknown.
    static func aheadSeconds(cachedBytesAhead: Int64, contentLength: Int64?, durationSeconds: Double) -> Double? {
        guard let contentLength, contentLength > 0, durationSeconds > 0 else { return nil }
        let bytesPerSecond = Double(contentLength) / durationSeconds
        guard bytesPerSecond > 0 else { return nil }
        return Double(max(cachedBytesAhead, 0)) / bytesPerSecond
    }
}
