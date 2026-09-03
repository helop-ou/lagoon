import Foundation
import Testing
@testable import Lagoon

/// The wait between leaving the player and re-fetching what it played
/// (HEL-132). Timing assertions use generous bounds: the point is the
/// ordering, not the milliseconds.
@Suite("Playback report ledger")
struct PlaybackReportLedgerTests {
    @Test @MainActor func settlingWithNothingOpenReturnsAtOnce() async {
        let ledger = PlaybackReportLedger()
        let clock = ContinuousClock()
        let started = clock.now
        await ledger.settle(timeout: .seconds(5))
        #expect(clock.now - started < .seconds(1))
        #expect(!ledger.hasOpenSessions)
    }

    @Test @MainActor func settlingWaitsForTheOpenSessionToClose() async {
        let ledger = PlaybackReportLedger()
        let session = ledger.open()
        #expect(ledger.hasOpenSessions)
        let clock = ContinuousClock()
        let started = clock.now
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            ledger.close(session)
        }
        await ledger.settle(timeout: .seconds(5))
        let elapsed = clock.now - started
        #expect(elapsed >= .milliseconds(80))
        #expect(elapsed < .seconds(2))
        #expect(!ledger.hasOpenSessions)
    }

    /// A report that never returns must not hang the screen underneath; it
    /// re-fetches after the timeout exactly as it did before the ledger.
    @Test @MainActor func settlingGivesUpAfterTheTimeout() async {
        let ledger = PlaybackReportLedger()
        _ = ledger.open()
        let clock = ContinuousClock()
        let started = clock.now
        await ledger.settle(timeout: .milliseconds(150))
        #expect(clock.now - started >= .milliseconds(150))
        #expect(ledger.hasOpenSessions)
    }

    @Test @MainActor func everyOpenSessionHasToCloseBeforeSettling() async {
        let ledger = PlaybackReportLedger()
        let first = ledger.open()
        let second = ledger.open()
        let waiter = Task { await ledger.settle(timeout: .seconds(5)) }
        // Give the waiter a chance to register before the first close.
        await Task.yield()
        ledger.close(first)
        #expect(ledger.hasOpenSessions)
        // The waiter can only have finished through the second close or the
        // five-second timeout, so yielding here proves it is still waiting.
        await Task.yield()
        ledger.close(second)
        await waiter.value
        #expect(!ledger.hasOpenSessions)
    }

    @Test @MainActor func closingAnUnknownSessionIsHarmless() async {
        let ledger = PlaybackReportLedger()
        ledger.close(UUID())
        #expect(!ledger.hasOpenSessions)
        await ledger.settle(timeout: .seconds(5))
    }

    /// The timeout keeps ticking after a close resumed the waiter; when it
    /// fires it must find nothing to resume rather than resume twice.
    @Test @MainActor func aLateTimeoutAfterACloseDoesNotResumeTwice() async {
        let ledger = PlaybackReportLedger()
        let session = ledger.open()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            ledger.close(session)
        }
        await ledger.settle(timeout: .milliseconds(80))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!ledger.hasOpenSessions)
    }

    /// Two screens waiting on the same report both wake on the close.
    @Test @MainActor func everyWaiterWakesOnTheLastClose() async {
        let ledger = PlaybackReportLedger()
        let session = ledger.open()
        let clock = ContinuousClock()
        let started = clock.now
        async let a: Void = ledger.settle(timeout: .seconds(5))
        async let b: Void = ledger.settle(timeout: .seconds(5))
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            ledger.close(session)
        }
        _ = await (a, b)
        #expect(clock.now - started < .seconds(2))
    }
}
