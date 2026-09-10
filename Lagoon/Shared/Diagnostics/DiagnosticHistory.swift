import Foundation

/// The bounded rolling history an incident carries with it: the last
/// `capacity` events, trimmed to `window` seconds when snapshotted. A value
/// type so a test can drive it deterministically; `DiagnosticsHub` owns the
/// live one behind a lock.
nonisolated struct DiagnosticHistory: Equatable, Sendable {
    static let defaultCapacity = 240
    static let defaultWindow: TimeInterval = 90

    let capacity: Int
    let window: TimeInterval
    private(set) var events: [DiagnosticEvent] = []

    init(capacity: Int = defaultCapacity, window: TimeInterval = defaultWindow) {
        self.capacity = max(capacity, 1)
        self.window = max(window, 1)
    }

    mutating func append(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    mutating func removeAll() {
        events.removeAll(keepingCapacity: true)
    }

    /// Everything recorded within `window` seconds before `now`, oldest
    /// first. Events stamped in the future (a clock that went backwards)
    /// are kept rather than lost; they are still the most recent context.
    func snapshot(at now: TimeInterval) -> [DiagnosticEvent] {
        let cutoff = now - window
        return events.filter { $0.uptime >= cutoff }
    }

    /// When `code` was last recorded, if it is still in the buffer.
    func lastUptime(of code: DiagnosticEventCode) -> TimeInterval? {
        events.last { $0.code == code }?.uptime
    }
}
