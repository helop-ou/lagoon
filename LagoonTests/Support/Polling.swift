import Foundation

/// Shared poll-until-true loop for async test conditions. Every caller keeps
/// its own timeout, poll interval and on-timeout behavior (silent return,
/// `Issue.record`, or `#require`); this owns only the waiting loop, so those
/// behaviors stay exactly where each test expects them.
enum Polling {
    /// Polls a main-actor condition, for the common case of watching
    /// `@MainActor` model state. A `nil` `pollInterval` yields between checks
    /// instead of sleeping, for tests that don't drive a clock of their own.
    @MainActor
    static func untilMainActor(
        timeout: Duration,
        pollInterval: Duration? = nil,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            if let pollInterval {
                try await Task.sleep(for: pollInterval)
            } else {
                await Task.yield()
            }
        }
    }

    /// Nonisolated counterpart for conditions backed by thread-safe
    /// (lock-protected) state rather than main-actor state.
    static func until(
        timeout: Duration,
        pollInterval: Duration? = nil,
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            if let pollInterval {
                try await Task.sleep(for: pollInterval)
            } else {
                await Task.yield()
            }
        }
    }
}
