import Foundation

/// The one place a Jellyfin timestamp becomes a number: the deliberate
/// exception to "never decode `Date`". SyncPlay DTOs keep them as `String`.
///
/// .NET's `yyyy-MM-ddTHH:mm:ss[.f{0,7}]Z` has a variable number of
/// fractional digits, and `ISO8601DateFormatter` rejects 7, so this parses
/// by hand in UTC. Anything not UTC returns nil.
nonisolated enum JellyfinTimestamp {
    /// .NET's 100 ns tick, the same as positions.
    static let fractionalDigits = 7
    private static let ticksPerSecond: Double = 10_000_000

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Seconds since 1970, or nil. The fraction is parsed separately to keep
    /// sub-millisecond precision.
    static func seconds(_ string: String) -> Double? {
        var body = Substring(string)
        // UTC spellings only. A real offset is refused rather than guessed.
        if body.hasSuffix("Z") || body.hasSuffix("z") {
            body = body.dropLast()
        } else if body.hasSuffix("+00:00") || body.hasSuffix("-00:00") {
            body = body.dropLast(6)
        } else if body.hasSuffix("+0000") || body.hasSuffix("-0000") {
            body = body.dropLast(5)
        }

        let halves = body.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }

        let date = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard date.count == 3,
              let year = integer(date[0], digits: 4),
              let month = integer(date[1], digits: 2), (1...12).contains(month),
              let day = integer(date[2], digits: 2), (1...31).contains(day) else { return nil }

        var timeText = halves[1]
        var fraction = 0.0
        if let dot = timeText.firstIndex(of: ".") {
            guard let parsed = self.fraction(timeText[timeText.index(after: dot)...]) else { return nil }
            fraction = parsed
            timeText = timeText[..<dot]
        }

        let time = timeText.split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 3,
              let hour = integer(time[0], digits: 2), (0...23).contains(hour),
              let minute = integer(time[1], digits: 2), (0...59).contains(minute),
              // 60 is a leap second; the calendar rolls it forward.
              let second = integer(time[2], digits: 2), (0...60).contains(second) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let instant = utc.date(from: components) else { return nil }
        return instant.timeIntervalSince1970 + fraction
    }

    /// The wire form, with seven fractional digits and `Z`, for the `When`
    /// in `SyncPlay/Ready` and `SyncPlay/Buffering`.
    static func string(_ seconds: Double) -> String {
        let value = seconds.isFinite ? seconds : 0
        var whole = value.rounded(.down)
        var fractionTicks = Int(((value - whole) * ticksPerSecond).rounded())
        // Rounding the fraction can carry: .99999996 s is a whole second.
        if fractionTicks >= Int(ticksPerSecond) {
            fractionTicks -= Int(ticksPerSecond)
            whole += 1
        }
        let components = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: whole)
        )
        let date = "\(padded(components.year ?? 0, 4))-\(padded(components.month ?? 1, 2))-\(padded(components.day ?? 1, 2))"
        let time = "\(padded(components.hour ?? 0, 2)):\(padded(components.minute ?? 0, 2)):\(padded(components.second ?? 0, 2))"
        return "\(date)T\(time).\(padded(fractionTicks, fractionalDigits))Z"
    }

    /// Exactly `digits` ASCII digits. `Int(_:)` alone accepts a sign and
    /// would read a zone offset as an hour.
    private static func integer(_ text: Substring, digits: Int) -> Int? {
        guard text.count == digits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func fraction(_ digits: Substring) -> Double? {
        guard !digits.isEmpty, digits.count <= 9,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Double(digits) else { return nil }
        return value / pow(10, Double(digits.count))
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let text = String(max(value, 0))
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
