import Foundation

/// When an item will finish in wall-clock time. `PlayerEngine.rate`
/// survives a pause, so a paused item projects at its resume speed.
nonisolated enum PlaybackFinish {
    /// Beyond a day is live or an unknown duration.
    static let longestProjection: TimeInterval = 24 * 60 * 60

    static func date(from now: Date, remaining: TimeInterval, rate: Double) -> Date? {
        guard remaining.isFinite, remaining >= 0 else { return nil }
        let speed = rate.isFinite && rate > 0 ? rate : 1
        let seconds = remaining / speed
        guard seconds.isFinite, seconds <= longestProjection else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// Follows the locale's 12- or 24-hour clock.
    static func label(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        )
    }
}
