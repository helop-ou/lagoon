#if os(tvOS)
import Foundation
import Testing
@testable import Lagoon

@Suite("Profile button clock")
@MainActor
struct ProfileClockTests {
    private let time = try! Date("2026-11-03T15:07:00Z", strategy: .iso8601)
    private let utc = TimeZone(identifier: "UTC")!

    @Test func theClockFollowsTheHourCycleWithoutAMOrPM() {
        let twelveHour = Locale(identifier: "en_US")
        var components = Locale.Components(locale: twelveHour)
        components.hourCycle = .zeroToTwentyThree
        let twentyFourHour = Locale(components: components)

        #expect(TVProfileControl.clockText(for: time, locale: twelveHour, timeZone: utc) == "3:07")
        #expect(TVProfileControl.clockText(for: time, locale: twentyFourHour, timeZone: utc) == "15:07")
    }
}
#endif
