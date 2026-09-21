import Foundation

/// Client-side suppression, so a failure that repeats every second costs one
/// report and a count rather than the month's quota. Dashboard grouping
/// alone does not reduce event volume. Pure: the hub owns one
/// behind its lock and feeds it the clock.
nonisolated struct IncidentSuppressor: Equatable, Sendable {
    struct Limits: Equatable, Sendable {
        /// Reports allowed per fingerprint inside `window`.
        var perFingerprint = 3
        /// Reports allowed in total inside `window`, across fingerprints.
        var perWindow = 30
        /// Reports allowed for the life of the process.
        var perProcess = 120
        var window: TimeInterval = 3_600

        static let standard = Limits()
    }

    enum Decision: Equatable, Sendable {
        /// Report it, and say how many occurrences it stands for.
        case report(occurrences: Int)
        case suppress
    }

    private struct Entry: Equatable {
        var sentAt: [TimeInterval]
        var pendingOccurrences: Int
    }

    let limits: Limits
    private var entries: [String: Entry] = [:]
    private var windowSentAt: [TimeInterval] = []
    private var processSent = 0

    init(limits: Limits = .standard) {
        self.limits = limits
    }

    mutating func decide(fingerprint: [String], now: TimeInterval) -> Decision {
        let key = fingerprint.joined(separator: "|")
        var entry = entries[key] ?? Entry(sentAt: [], pendingOccurrences: 0)
        entry.pendingOccurrences += 1
        let cutoff = now - limits.window
        entry.sentAt.removeAll { $0 < cutoff }
        windowSentAt.removeAll { $0 < cutoff }

        let allowed = processSent < limits.perProcess
            && windowSentAt.count < limits.perWindow
            && entry.sentAt.count < limits.perFingerprint
        guard allowed else {
            entries[key] = entry
            return .suppress
        }
        let occurrences = entry.pendingOccurrences
        entry.pendingOccurrences = 0
        entry.sentAt.append(now)
        entries[key] = entry
        windowSentAt.append(now)
        processSent += 1
        return .report(occurrences: occurrences)
    }
}
