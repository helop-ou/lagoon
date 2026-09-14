import Foundation
import Testing
@testable import Lagoon

/// The arithmetic behind staying in sync (HEL-172): how far out is far
/// enough to act, what acting costs, and when a named server instant
/// arrives on this clock.
@Suite("SyncPlay correction")
struct SyncCorrectionPolicyTests {
    @Test func aDifferenceNobodyCanSeeIsLeftAlone() {
        #expect(SyncCorrectionPolicy.decision(diff: 0) == .none)
        #expect(SyncCorrectionPolicy.decision(diff: 0.059) == .none)
        #expect(SyncCorrectionPolicy.decision(diff: -0.059) == .none)
        #expect(SyncCorrectionPolicy.decision(diff: .nan) == .none)
    }

    @Test func beingBehindSpeedsUpAndBeingAheadSlowsDown() throws {
        guard case .rate(let faster, let hold) = SyncCorrectionPolicy.decision(diff: 0.75) else {
            Issue.record("expected a rate correction")
            return
        }
        // Half a window behind: half again as fast, for one window, which
        // is exactly the gap.
        #expect(abs(faster - 1.5) < 0.000_001)
        #expect(hold == .seconds(1.5))

        guard case .rate(let slower, _) = SyncCorrectionPolicy.decision(diff: -0.3) else {
            Issue.record("expected a rate correction")
            return
        }
        #expect(abs(slower - 0.8) < 0.000_001)
    }

    @Test func aCorrectionStaysInsideTheAudibleEnvelope() throws {
        guard case .rate(let slowest, _) = SyncCorrectionPolicy.decision(diff: -1.5) else {
            Issue.record("expected a rate correction")
            return
        }
        // 1 + (−1.5 / 1.5) is 0, which would stop the clock.
        #expect(slowest == SyncCorrectionPolicy.minimumMultiplier)
        guard case .rate(let fastest, _) = SyncCorrectionPolicy.decision(diff: 1.5) else {
            Issue.record("expected a rate correction")
            return
        }
        #expect(fastest == SyncCorrectionPolicy.maximumMultiplier)
    }

    @Test func beingSomewhereElseEntirelySeeks() {
        #expect(SyncCorrectionPolicy.decision(diff: 1.51) == .seek)
        #expect(SyncCorrectionPolicy.decision(diff: -12) == .seek)
    }

    @Test func theExpectedPositionRunsWithTheServersClock() {
        let expected = SyncCorrectionPolicy.expectedPosition(
            commandPosition: 120,
            commandWhenServerSeconds: 1_000,
            serverSeconds: 1_012.5
        )
        #expect(abs(expected - 132.5) < 0.000_001)
    }

    /// A group start instant is in the future when it arrives; a pause
    /// instant can already be gone by the time it is read.
    @Test func aServerInstantBecomesALocalWait() {
        // The server's clock runs 4 s ahead: its 1 004 is our 1 000.
        let waiting = SyncPlayCommandSchedule.delaySeconds(
            whenServerSeconds: 1_004.5,
            clockOffset: 4,
            nowSeconds: 1_000
        )
        #expect(abs(waiting - 0.5) < 0.000_001)
        #expect(!SyncPlayCommandSchedule.isPast(whenServerSeconds: 1_004.5, clockOffset: 4, nowSeconds: 1_000))
    }

    @Test func anInstantAlreadyGoneIsActedOnAtOnce() {
        #expect(SyncPlayCommandSchedule.delaySeconds(
            whenServerSeconds: 1_000,
            clockOffset: 0,
            nowSeconds: 1_002
        ) == 0)
        #expect(SyncPlayCommandSchedule.isPast(whenServerSeconds: 1_000, clockOffset: 0, nowSeconds: 1_002))
        #expect(SyncPlayCommandSchedule.delay(
            whenServerSeconds: .nan,
            clockOffset: 0,
            nowSeconds: 1_000
        ) == .zero)
    }
}
