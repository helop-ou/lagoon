import Foundation
import OSLog

private let log = Logger(subsystem: "ee.helop.lagoon", category: "playback-reports")

/// The playback sessions whose final `Sessions/Playing/Stopped` report the
/// server may not have applied yet (HEL-132).
///
/// Leaving the player and re-fetching what it played are deliberately
/// independent: the stop report is fire-and-forget so a slow server never
/// delays dismissal, and the screen underneath re-fetches in its
/// `fullScreenCover`'s `onDismiss`. Left alone the two race — the report
/// only starts from the player's `onDisappear`, in the same run-loop turn
/// as `onDismiss` — and the re-fetch usually wins, so a detail page reads
/// the position the server had *before* the report and keeps offering Play
/// where it should offer Resume.
///
/// The player opens a session here at the moment its server-side playback
/// session becomes active and closes it once the stop report has returned,
/// or once it is certain nothing will be reported. A screen calls `settle()`
/// before it re-fetches. `settle()` is bounded: a screen must never hang on
/// a report that fails to return, so after the timeout it re-fetches exactly
/// as it did before this existed.
final class PlaybackReportLedger {
    /// Long enough for a stop report on a slow remote server (a real stop
    /// took 2.6 s against fixture, most of it the server tearing the session
    /// down), short enough that a server that has gone away costs one
    /// visible pause, not a hang.
    nonisolated static let defaultSettleTimeout: Duration = .seconds(8)

    private var openSessions: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var hasOpenSessions: Bool { !openSessions.isEmpty }

    /// The server now holds a playback session whose stop report has not
    /// returned yet.
    func open() -> UUID {
        let session = UUID()
        openSessions.insert(session)
        log.debug("open \(session.uuidString.prefix(8), privacy: .public); \(self.openSessions.count) open")
        return session
    }

    /// The stop report for `session` has returned, or will never be sent.
    /// Closing a session that is not open is harmless.
    func close(_ session: UUID) {
        openSessions.remove(session)
        log.debug("close \(session.uuidString.prefix(8), privacy: .public); \(self.openSessions.count) open, \(self.waiters.count) waiting")
        guard openSessions.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }

    /// Returns once no session is open, or after `timeout`, whichever comes
    /// first. Returns at once when nothing is open, so callers can wait
    /// unconditionally before a re-fetch.
    func settle(timeout: Duration = PlaybackReportLedger.defaultSettleTimeout) async {
        guard hasOpenSessions else {
            log.notice("settle: nothing open")
            return
        }
        let waiter = UUID()
        let clock = ContinuousClock()
        let started = clock.now
        await withCheckedContinuation { continuation in
            waiters[waiter] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                if self.resume(waiter) {
                    log.error("settle: timed out after \(timeout); \(self.openSessions.count) still open")
                }
            }
        }
        log.notice("settle: waited \(clock.now - started)")
    }

    /// Exactly-once by construction: whichever of `close` and the timeout
    /// comes second finds nothing to resume.
    @discardableResult
    private func resume(_ waiter: UUID) -> Bool {
        guard let continuation = waiters.removeValue(forKey: waiter) else { return false }
        continuation.resume()
        return true
    }
}
