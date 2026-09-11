import Foundation
import Testing
@testable import Lagoon

/// Pure scheduler-policy coverage (HEL-160): no cache, no clock, no engine —
/// just the decision table `PlaybackController.startBufferFill` drives.
@Suite("Playback fill policy")
struct PlaybackFillPolicyTests {
    // MARK: - beforeFetch

    @Test func completeWholeFileStopsTheLoop() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.bufferedFraction = 1
        snapshot.isWindowed = false
        #expect(policy.beforeFetch(snapshot) == .stop)
    }

    @Test func completeButWindowedKeepsFetching() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.bufferedFraction = 1
        snapshot.isWindowed = true
        #expect(policy.beforeFetch(snapshot) == .fetch)
    }

    @Test func bufferingRendererGetsTheLinkToItselfForACooldown() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.isBuffering = true
        #expect(policy.beforeFetch(snapshot) == .wait(PlaybackFillPolicy.stallCooldownSeconds))
    }

    @Test func aNewStallGetsTheLinkToItselfForACooldown() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.newStall = true
        #expect(policy.beforeFetch(snapshot) == .wait(PlaybackFillPolicy.stallCooldownSeconds))
    }

    @Test func ordinarilyBeforeFetchProceeds() {
        let policy = PlaybackFillPolicy()
        #expect(policy.beforeFetch(PlaybackFillPolicy.Snapshot()) == .fetch)
    }

    // MARK: - afterFetch: cancellation & exhaustion

    @Test func cancellationAlwaysStops() {
        var policy = PlaybackFillPolicy()
        #expect(policy.afterFetch(.cancelled, PlaybackFillPolicy.Snapshot()) == .stop)
    }

    @Test func exhaustedWindowedWaitsForThePlayheadToMakeRoom() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.isWindowed = true
        #expect(policy.afterFetch(.exhausted, snapshot) == .wait(PlaybackFillPolicy.idlePollSeconds))
    }

    @Test func exhaustedWholeFileStops() {
        var policy = PlaybackFillPolicy()
        #expect(policy.afterFetch(.exhausted, PlaybackFillPolicy.Snapshot()) == .stop)
    }

    @Test func exhaustionResetsTheFailureBackoff() {
        var policy = PlaybackFillPolicy()
        let snapshot = PlaybackFillPolicy.Snapshot()
        _ = policy.afterFetch(.failed, snapshot)
        _ = policy.afterFetch(.failed, snapshot)
        #expect(policy.consecutiveFailures == 2)

        _ = policy.afterFetch(.exhausted, snapshot)
        #expect(policy.consecutiveFailures == 0)
        #expect(policy.afterFetch(.failed, snapshot) == .wait(1))
    }

    // MARK: - afterFetch: failure backoff

    @Test func aFailureBacksOffExponentiallyUpToTheCap() {
        var policy = PlaybackFillPolicy()
        let snapshot = PlaybackFillPolicy.Snapshot()
        let expectedWaits: [Double] = [1, 2, 4, 8, 16, 30, 30]
        for expected in expectedWaits {
            #expect(policy.afterFetch(.failed, snapshot) == .wait(expected))
        }
    }

    @Test func aFetchedOutcomeResetsTheFailureBackoff() {
        var policy = PlaybackFillPolicy()
        let stalledSnapshot = PlaybackFillPolicy.Snapshot()
        _ = policy.afterFetch(.failed, stalledSnapshot)
        _ = policy.afterFetch(.failed, stalledSnapshot)
        #expect(policy.consecutiveFailures == 2)

        var pausedSnapshot = PlaybackFillPolicy.Snapshot()
        pausedSnapshot.isPaused = true
        _ = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.1), pausedSnapshot)
        #expect(policy.consecutiveFailures == 0)

        // The next failure waits a fresh 1 second rather than continuing the
        // old exponent.
        #expect(policy.afterFetch(.failed, stalledSnapshot) == .wait(1))
    }

    // MARK: - afterFetch: fetched, paused

    @Test func fetchedWhilePausedGoesFullSpeed() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.isPaused = true
        #expect(policy.afterFetch(.fetched(bytes: 1_000, seconds: 5), snapshot) == .fetch)
    }

    // MARK: - afterFetch: fetched, playing, below the cushion target (hurried)

    @Test func hurriedPacingYieldsAFractionOfTheLastRequestsOwnTime() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.2), snapshot)
        expectWait(decision, 0.1)
    }

    @Test func hurriedPacingCapsItsYield() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 4), snapshot)
        expectWait(decision, PlaybackFillPolicy.hurriedYieldCapSeconds)
    }

    @Test func anUnknownCushionIsTreatedAsHurried() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = nil
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.2), snapshot)
        expectWait(decision, 0.1)
    }

    // MARK: - afterFetch: fetched, playing, at/above the cushion target (relaxed)

    @Test func relaxedPacingMultipliesTheLastRequestsOwnTime() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = PlaybackFillPolicy.targetAheadSeconds
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.5), snapshot)
        expectWait(decision, 2)
    }

    @Test func relaxedPacingFloorsAtTheMinimumMeasuredRequest() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = PlaybackFillPolicy.targetAheadSeconds + 1
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.01), snapshot)
        expectWait(decision, 0.5)
    }

    @Test func relaxedPacingCapsItsWait() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = PlaybackFillPolicy.targetAheadSeconds
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 10), snapshot)
        expectWait(decision, PlaybackFillPolicy.relaxedPacingCapSeconds)
    }

    // MARK: - aheadSeconds(cachedBytesAhead:contentLength:durationSeconds:)

    @Test func aheadSecondsProjectsCachedBytesThroughTheAverageBitrate() {
        let mebibyte: Int64 = 1_024 * 1_024
        let ahead = PlaybackFillPolicy.aheadSeconds(
            cachedBytesAhead: 60 * mebibyte,
            contentLength: 600 * mebibyte,
            durationSeconds: 6_000
        )
        #expect(ahead != nil)
        #expect(abs((ahead ?? 0) - 600) < 1e-9)
    }

    @Test func aheadSecondsIsNilWithoutAKnownContentLengthOrDuration() {
        #expect(PlaybackFillPolicy.aheadSeconds(
            cachedBytesAhead: 100, contentLength: nil, durationSeconds: 100
        ) == nil)
        #expect(PlaybackFillPolicy.aheadSeconds(
            cachedBytesAhead: 100, contentLength: 100, durationSeconds: 0
        ) == nil)
    }

    // MARK: - Helpers

    private func waitSeconds(_ decision: PlaybackFillPolicy.Decision) -> Double? {
        if case .wait(let seconds) = decision { return seconds }
        return nil
    }

    private func expectWait(_ decision: PlaybackFillPolicy.Decision, _ expected: Double, tolerance: Double = 1e-9) {
        guard let seconds = waitSeconds(decision) else {
            Issue.record("Expected .wait(\(expected)), got \(decision)")
            return
        }
        #expect(abs(seconds - expected) < tolerance)
    }
}
