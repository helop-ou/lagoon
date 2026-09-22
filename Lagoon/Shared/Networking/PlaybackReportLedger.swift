import Foundation
import OSLog

private let log = Logger(subsystem: "ee.helop.lagoon", category: "playback-reports")

/// Playback sessions whose stop report the server may not have applied yet.
///
/// The stop report is fire-and-forget, and the screen underneath re-fetches
/// on dismiss. Unchecked, the re-fetch wins the race and shows Play instead
/// of Resume. Screens call `settle()` before re-fetching; it is bounded by a
/// timeout.
final class PlaybackReportLedger {
    /// Covers a slow server's stop report (2.6 s measured); a dead server
    /// costs one pause, not a hang.
    nonisolated static let defaultSettleTimeout: Duration = .seconds(8)

    private var openSessions: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var hasOpenSessions: Bool { !openSessions.isEmpty }

    /// A server session is active and its stop report has not returned.
    func open() -> UUID {
        let session = UUID()
        openSessions.insert(session)
        log.debug("open \(session.uuidString.prefix(8), privacy: .public); \(self.openSessions.count) open")
        return session
    }

    /// The stop report returned or will never be sent. Safe to repeat.
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

    /// Returns when no session is open or after `timeout`. Immediate when
    /// nothing is open, so callers can always wait.
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

    /// Exactly once: whichever of `close` and the timeout comes second
    /// finds nothing to resume.
    @discardableResult
    private func resume(_ waiter: UUID) -> Bool {
        guard let continuation = waiters.removeValue(forKey: waiter) else { return false }
        continuation.resume()
        return true
    }
}
