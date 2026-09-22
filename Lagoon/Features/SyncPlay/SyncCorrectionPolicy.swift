import Foundation

/// Graded drift correction: ignore what nobody can see, nudge the rate for
/// small gaps, and seek only when far off, since a seek is visible.
/// Pure, so the thresholds are pinned by tests.
nonisolated enum SyncCorrectionPolicy {
    /// Seconds. Below this, correcting would only oscillate; lip-sync
    /// tolerance is about 45 ms.
    static let deadband = 0.06
    /// Seconds. Beyond this, seek instead of nudging.
    static let seekThreshold = 1.5
    /// Seconds a correction is held, and the re-measure interval.
    static let window: Double = 1.5
    /// Outside this range the speed change is audible.
    static let minimumMultiplier = 0.75
    static let maximumMultiplier = 1.5
    /// Seconds after a start instant while renderers settle; not drift.
    static let settleSeconds: Double = 1.5
    static var settle: Duration { .seconds(settleSeconds) }
    static var interval: Duration { .seconds(window) }

    nonisolated enum Decision: Equatable, Sendable {
        case none
        case rate(multiplier: Double, hold: Duration)
        case seek
    }

    /// `diff` is expected minus actual: positive means *behind*.
    static func decision(diff: Double) -> Decision {
        guard diff.isFinite else { return .none }
        let magnitude = abs(diff)
        if magnitude < deadband { return .none }
        if magnitude > seekThreshold { return .seek }
        // Closes the gap in one window: 0.75 s behind runs 1.5× for 1.5 s.
        let multiplier = min(max(1 + diff / window, minimumMultiplier), maximumMultiplier)
        return .rate(multiplier: multiplier, hold: .seconds(window))
    }

    /// The command's position plus server time elapsed since its instant.
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

/// Turns a server instant into a local wait. Pure and tested: one sign
/// error pauses the group seconds apart.
nonisolated enum SyncPlayCommandSchedule {
    /// Seconds, never negative: a past instant acts at once.
    static func delaySeconds(
        whenServerSeconds: Double,
        clockOffset: Double,
        nowSeconds: Double
    ) -> Double {
        guard whenServerSeconds.isFinite, clockOffset.isFinite, nowSeconds.isFinite else { return 0 }
        // The server clock runs `clockOffset` ahead of this one.
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
