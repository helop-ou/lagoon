import Foundation

/// The state behind one optimistic server toggle such as watched or
/// favourite. The icon flips the moment the viewer presses,
/// because a toggle that waits on a round trip feels broken; what happens
/// afterwards is the part that used to be missing:
///
/// - **Refusal** reverts the icon and records which value the server
///   refused, so the row can say so instead of silently snapping back.
/// - **Acceptance** hands authority back to the server. Once the page has
///   re-fetched the item, the local override is dropped and the icon shows
///   whatever the server now says, so a change made on another client, or a
///   server that accepted the request but disagreed, reaches the screen. If
///   the re-fetch failed, the override stays: the server did accept.
/// - **A press during a request** is ignored rather than sent, so two
///   overlapping requests cannot leave the icon and the server disagreeing.
///
/// Pure so the transitions can be pinned in `OptimisticToggleStateTests`.
nonisolated struct OptimisticToggleState: Equatable, Sendable {
    /// The value the viewer asked for, shown in place of the server's until
    /// the server has either refused it or been re-read after accepting it.
    private(set) var override: Bool?
    /// The value of the request in flight, nil when none is.
    private(set) var pendingTarget: Bool?
    /// The value the server refused most recently, for the row's feedback;
    /// cleared by `dismissFailure()` or the next press.
    private(set) var refusedTarget: Bool?

    var isInFlight: Bool { pendingTarget != nil }

    /// What the icon shows: the viewer's pending or unreconciled choice, else
    /// the server's flag, else off.
    func value(server: Bool?) -> Bool {
        override ?? server ?? false
    }

    /// The viewer pressed. Returns the value to send, or nil when a request
    /// is already in flight and the press is dropped.
    mutating func begin(server: Bool?) -> Bool? {
        guard !isInFlight else { return nil }
        let target = !value(server: server)
        override = target
        pendingTarget = target
        refusedTarget = nil
        return target
    }

    /// The server accepted. `refreshed` says whether the page then re-read
    /// the item from the server; only then is the override dropped.
    mutating func succeed(refreshed: Bool) {
        pendingTarget = nil
        if refreshed {
            override = nil
        }
    }

    /// The server refused or the request failed: revert, and remember what
    /// was refused so the row can say so.
    mutating func fail() {
        refusedTarget = pendingTarget
        pendingTarget = nil
        override = nil
    }

    mutating func dismissFailure() {
        refusedTarget = nil
    }

    /// The row now shows a different item: nothing carried over applies.
    /// The caller ignores the outcome of any request still in flight for the
    /// old item.
    mutating func itemChanged() {
        self = OptimisticToggleState()
    }
}
