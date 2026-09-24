import Foundation
import LagoonEngine

/// The last `capacity` events, trimmed to `window` seconds on snapshot.
/// `DiagnosticsHub` owns the live one behind a lock.
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

    /// Oldest first. Events stamped in the future (clock went backwards)
    /// are kept.
    func snapshot(at now: TimeInterval) -> [DiagnosticEvent] {
        let cutoff = now - window
        return events.filter { $0.uptime >= cutoff }
    }

    /// When `code` was last recorded, if it is still in the buffer.
    func lastUptime(of code: DiagnosticEventCode) -> TimeInterval? {
        events.last { $0.code == code }?.uptime
    }
}
