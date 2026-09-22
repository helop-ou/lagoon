import Foundation

/// One optimistic server toggle, such as watched or favourite. The icon flips
/// on press.
///
/// - **Refusal** reverts and records the refused value so the row can say so.
/// - **Acceptance** drops the override once the page re-fetches, so changes
///   from other clients show. If the re-fetch failed, the override stays.
/// - **A press during a request** is dropped, so overlapping requests cannot
///   leave icon and server disagreeing.
///
/// Pinned in `OptimisticToggleStateTests`.
nonisolated struct OptimisticToggleState: Equatable, Sendable {
    /// The viewer's value, shown until refused or re-read after acceptance.
    private(set) var override: Bool?
    private(set) var pendingTarget: Bool?
    /// Cleared by `dismissFailure()` or the next press.
    private(set) var refusedTarget: Bool?

    var isInFlight: Bool { pendingTarget != nil }

    func value(server: Bool?) -> Bool {
        override ?? server ?? false
    }

    /// Returns the value to send, or nil when a request is in flight.
    mutating func begin(server: Bool?) -> Bool? {
        guard !isInFlight else { return nil }
        let target = !value(server: server)
        override = target
        pendingTarget = target
        refusedTarget = nil
        return target
    }

    /// The override drops only when `refreshed`: the page re-read the item.
    mutating func succeed(refreshed: Bool) {
        pendingTarget = nil
        if refreshed {
            override = nil
        }
    }

    /// Refused or failed: revert and remember the refused value.
    mutating func fail() {
        refusedTarget = pendingTarget
        pendingTarget = nil
        override = nil
    }

    mutating func dismissFailure() {
        refusedTarget = nil
    }

    /// The caller ignores any request still in flight for the old item.
    mutating func itemChanged() {
        self = OptimisticToggleState()
    }
}
