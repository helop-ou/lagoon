import Foundation

/// The one place a Jellyfin wall-clock timestamp becomes a number, and the
/// deliberate exception to "no `Date` is decoded anywhere".
///
/// SyncPlay is the first feature that needs an instant rather than a
/// duration: a `SendCommand` says *when*, on the server's clock, every
/// client should unpause, and `GetUtcTime` reports when the server received
/// and answered a request. Those cannot be modelled as ticks. They stay
/// `String` on the DTOs — nothing decodes a `Date` — and are converted here,
/// at the one boundary where a number is actually wanted.
///
/// The format is .NET's: `yyyy-MM-ddTHH:mm:ss[.f{0,7}]Z`, with a *variable*
/// number of fractional digits (6 and 7 both observed on fixture 12.0.0 in
/// the same minute). `ISO8601DateFormatter` rejects 7 of them, which is the
/// original reason the codebase models no dates at all, so this parses the
/// components itself and builds the instant through a fixed UTC Gregorian
/// calendar. Anything that is not UTC — a real zone offset, a malformed
/// field — returns nil rather than a plausible wrong answer.
nonisolated enum JellyfinTimestamp {
    /// .NET's fractional resolution: 100 ns, the same tick used for
    /// positions. The wire carries at most seven digits of it.
    static let fractionalDigits = 7
    private static let ticksPerSecond: Double = 10_000_000

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Seconds since 1970 for a server timestamp, or nil if it is not one.
    ///
    /// Sub-millisecond precision survives: the fraction is parsed separately
    /// and added to the whole second, so a 7-digit `.2805781` is kept to
    /// roughly half a microsecond — the resolution a `Double` of epoch
    /// seconds has left in 2026, and two orders of magnitude finer than the
    /// 60–100 ms round trip it is used to measure.
    static func seconds(_ string: String) -> Double? {
        var body = Substring(string)
        // Jellyfin emits UTC in one of these spellings. A genuine offset is
        // refused: no SyncPlay server sends one, and guessing at one would
        // put the group hours out rather than visibly failing.
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
              // 60 is a leap second. .NET never emits one; accepting it and
              // letting the calendar roll it forward beats refusing a valid
              // instant over a value this parser has no opinion about.
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

    /// The wire spelling of an instant, always with seven fractional digits
    /// and a `Z`. This is what goes back to the server in `SyncPlay/Ready`
    /// and `SyncPlay/Buffering`, whose `When` it compares against its own
    /// clock.
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

    /// Exactly `digits` ASCII digits, so `+7`, ` 7` and `7` are all refused
    /// where `07` is wanted. `Int(_:)` alone accepts a sign and would read a
    /// zone offset as an hour.
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
