import Foundation

/// How a member that has drifted from its group gets back in line.
///
/// A member's clock is never exactly the group's: the start instant is
/// honoured to a frame or two, then decode, display cadence and swallowed
/// stalls pull it apart by tens of milliseconds a minute. Seeking every time
/// would be worse than the drift — a seek re-primes the pipeline and is
/// visible. So it is graded: ignore what nobody can see, ride the rate back
/// for anything a nudge absorbs, seek only when the member is elsewhere.
///
/// Pure, so the thresholds are pinned by tests.
nonisolated enum SyncCorrectionPolicy {
    /// Below this nothing is done. Lip sync tolerance is around 45 ms of
    /// audio lead; two members 60 ms apart are watching the same thing, and
    /// a correction here would be a permanent small oscillation.
    static let deadband = 0.06
    /// Beyond this a nudge cannot close the gap in a reasonable time and
    /// the member seeks instead. It is also the window the nudge is sized
    /// to: a `diff` of exactly this much is a 1.5× rate held for 1.5 s.
    static let seekThreshold = 1.5
    /// How long one correction is held before the rate returns to the
    /// viewer's own, and how often the drift is re-measured. One window is
    /// one full correction: measure, nudge, restore, measure again.
    static let window: Double = 1.5
    /// The envelope a correction may use. Faster than 1.5× or slower than
    /// 0.75× is audible as pitch-free speed change even when the video
    /// hides it.
    static let minimumMultiplier = 0.75
    static let maximumMultiplier = 1.5
    /// How long after a group start instant drift is left alone. The first
    /// seconds after an anchor are the renderers settling, not drift.
    static let settleSeconds: Double = 1.5
    static var settle: Duration { .seconds(settleSeconds) }
    static var interval: Duration { .seconds(window) }

    nonisolated enum Decision: Equatable, Sendable {
        case none
        /// Run at `multiplier` times the viewer's rate for `hold`, then
        /// back to it.
        case rate(multiplier: Double, hold: Duration)
        /// Too far out to nudge: go to the expected position.
        case seek
    }

    /// `diff` is expected minus actual: positive means the member is
    /// *behind* the group and has to speed up.
    static func decision(diff: Double) -> Decision {
        guard diff.isFinite else { return .none }
        let magnitude = abs(diff)
        if magnitude < deadband { return .none }
        if magnitude > seekThreshold { return .seek }
        // Sized to close the gap over one window: a member 0.75 s behind
        // runs at 1.5× for 1.5 s, which is exactly 0.75 s of catching up.
        let multiplier = min(max(1 + diff / window, minimumMultiplier), maximumMultiplier)
        return .rate(multiplier: multiplier, hold: .seconds(window))
    }

    /// Where a member should be now, given the command that started it.
    /// The group named a position and the instant to present it at; every
    /// second of server time since is a second of media.
    static func expectedPosition(
        commandPosition: Double,
        commandWhenServerSeconds: Double,
        serverSeconds: Double
    ) -> Double {
        guard commandPosition.isFinite,
              commandWhenServerSeconds.isFinite,
              serverSeconds.isFinite else { return commandPosition }
        return commandPosition + (serverSeconds - commandWhenServerSeconds)
    }
}

/// Turning a server instant into a local wait.
///
/// A `Pause` command names the instant every member should stop at, and a
/// member that stops when the message arrives stops early by its own
/// latency. Pure for the same reason as the policy above: this arithmetic
/// is one sign error away from a group that pauses two seconds apart.
nonisolated enum SyncPlayCommandSchedule {
    /// How long to wait locally before acting, in seconds. Never negative:
    /// an instant already gone is acted on at once.
    static func delaySeconds(
        whenServerSeconds: Double,
        clockOffset: Double,
        nowSeconds: Double
    ) -> Double {
        guard whenServerSeconds.isFinite, clockOffset.isFinite, nowSeconds.isFinite else { return 0 }
        // The server's clock runs `clockOffset` ahead of this one, so the
        // local instant of a server instant is the server instant minus
        // the offset.
        return max((whenServerSeconds - clockOffset) - nowSeconds, 0)
    }

    static func delay(
        whenServerSeconds: Double,
        clockOffset: Double,
        nowSeconds: Double
    ) -> Duration {
        .seconds(delaySeconds(
            whenServerSeconds: whenServerSeconds,
            clockOffset: clockOffset,
            nowSeconds: nowSeconds
        ))
    }

    /// Whether the instant has already passed, i.e. there is nothing to
    /// wait for.
    static func isPast(
        whenServerSeconds: Double,
        clockOffset: Double,
        nowSeconds: Double
    ) -> Bool {
        delaySeconds(
            whenServerSeconds: whenServerSeconds,
            clockOffset: clockOffset,
            nowSeconds: nowSeconds
        ) <= 0
    }
}
