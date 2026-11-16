import Foundation
import Testing
@testable import Lagoon

@Suite("Santa's sleigh")
@MainActor
struct SantaFlightTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Tallinn")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Noon, so the store's own calendar agrees on the day in any time zone
    /// the tests run in.
    private static func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day, hour: 12
        ))!
    }

    private func defaults() -> UserDefaults {
        let suite = "SantaFlightTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static let tv = CGSize(width: 1920, height: 1080)
    private static let phone = CGSize(width: 402, height: 874)

    // MARK: - When

    @Test(arguments: Array(2026...2046))
    func theSleighFliesOnChristmasEveAndChristmasDayEveryYear(year: Int) throws {
        let calendar = Self.calendar
        #expect(Christmas.day(on: Self.date(year, 12, 23, 23), calendar: calendar) == nil)
        let eve = try #require(Christmas.day(on: Self.date(year, 12, 24, 0), calendar: calendar))
        let day = try #require(Christmas.day(on: Self.date(year, 12, 25, 23), calendar: calendar))
        #expect(eve != day)
        #expect(Christmas.day(on: Self.date(year, 12, 24, 22), calendar: calendar) == eve)
        #expect(Christmas.day(on: Self.date(year, 12, 26, 0), calendar: calendar) == nil)
        #expect(Christmas.day(on: Self.date(year, 6, 24), calendar: calendar) == nil)
        // Next year's are new days, so it flies again.
        #expect(Christmas.day(on: Self.date(year + 1, 12, 24), calendar: calendar) != eve)
        #expect(Christmas.day(on: Self.date(year + 1, 12, 25), calendar: calendar) != day)
    }

    @Test func aProfileSeesTheSleighOnceOnEachOfTheTwoDays() {
        let defaults = defaults()
        var today = Self.noon(2026, 12, 23)
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "a")
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 0)

        today = Self.noon(2026, 12, 24)
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 1)
        // Not again that day, however often Lagoon comes back.
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 1)
        // Another profile has its own, and the first is still done.
        store.configure(accountID: "b")
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 2)
        store.configure(accountID: "a")
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 2)

        // Once more on Christmas Day, then not until next year.
        today = Self.noon(2026, 12, 25)
        store.welcomeSantaIfDue()
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 3)
        today = Self.noon(2026, 12, 26)
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 3)
        today = Self.noon(2027, 12, 24)
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 4)
    }

    @Test func aProfileThatTurnedTheSeasonsOffGetsNoSleigh() {
        let store = ThemeStore(defaults: defaults(), now: { Self.noon(2026, 12, 24) })
        store.configure(accountID: "a")
        store.setFollowsSeasons(false)
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 0)
        // Turned back on that day, it is still owed.
        store.setFollowsSeasons(true)
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 1)
    }

    @Test func nobodySignedInGetsNoSleighAndUsesNobodysTurn() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, now: { Self.noon(2026, 12, 24) })
        store.welcomeSantaIfDue()
        #expect(store.santaCount == 0)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(ThemeStore.santaKeyPrefix) })
    }

    @Test func forgettingAnAccountForgetsItsSleighToo() {
        #expect(AccountLocalData.perAccountKeyPrefixes.contains(ThemeStore.santaKeyPrefix))
    }

    // MARK: - Where

    /// From the lead's nose off one edge to the sleigh's back off the other.
    @Test(arguments: [tv, phone])
    func theTeamEntersAndLeavesOffThePage(page: CGSize) {
        let unit = SantaFlight.scale(in: page)
        let lead = (SantaFlight.pairs.last ?? 0) + SantaFlight.farOffset.x + SantaGeometry.nose.x
        #expect(SantaFlight.sleighX(at: 0, in: page) + lead * unit < 0)
        #expect(SantaFlight.sleighX(at: SantaFlight.crossing, in: page) - 95 * unit > page.width)
        // Steadily, with no pause on the way.
        let middle = SantaFlight.sleighX(at: SantaFlight.crossing / 2, in: page)
        let ends = SantaFlight.sleighX(at: 0, in: page) + SantaFlight.sleighX(at: SantaFlight.crossing, in: page)
        #expect(abs(middle - ends / 2) < 0.001)
    }

    @Test(arguments: [tv, phone])
    func theTeamIsNeitherLostOnATelevisionNorCrampedOnAPhone(page: CGSize) {
        let width = SantaFlight.scale(in: page) * SantaFlight.teamLength
        #expect(width >= 280)
        #expect(width <= min(900, page.width * 0.75))
    }

    @Test(arguments: [tv, phone])
    func theFlightClimbsToItsHighestPastTheMiddleAndStaysInTheUpperHalf(page: CGSize) {
        let heights = stride(from: 0.0, through: 1.0, by: 0.02).map { SantaFlight.height(at: $0 * page.width, in: page) }
        let highest = heights.enumerated().min { $0.element < $1.element }
        #expect((0.5...0.62).contains(Double(highest?.offset ?? 0) * 0.02))
        #expect(heights.allSatisfy { $0 > page.height * 0.2 && $0 < page.height * 0.5 })
        #expect(heights[0] > heights[25])
    }

    /// A tall page keeps the climb its width allows.
    @Test func aPhoneKeepsTheTeamFromStandingOnEnd() {
        func steepest(in page: CGSize) -> Double {
            (0...40).map { index in
                abs(SantaFlight.placement(ahead: 0, at: Double(index) / 40 * SantaFlight.crossing, in: page).turn)
            }.max() ?? 0
        }
        #expect(steepest(in: Self.phone) < 0.5)
        #expect(steepest(in: Self.tv) < 0.5)
    }

    @Test func aReindeersLegsGatherAndStretchInStep() {
        let strides = stride(from: 0.0, through: 2.0, by: 0.01).map { SantaFlight.stride(at: $0, phase: 0) }
        #expect(strides.allSatisfy { (0...1).contains($0) })
        #expect((strides.min() ?? 1) < 0.01)
        #expect((strides.max() ?? 0) > 0.99)
        // The far reindeer of a pair is out of step with the near one.
        #expect(abs(SantaFlight.stride(at: 0.3, phase: 0) - SantaFlight.stride(at: 0.3, phase: 1.1)) > 0.1)
        let legs = SantaGeometry.legs(stride: 0)
        let gathered = SantaGeometry.legs(stride: 1)
        #expect(legs.count == 4)
        #expect(zip(legs, gathered).allSatisfy { $0.hip == $1.hip && $0.hoof != $1.hoof })
    }

    // MARK: - Dust

    @Test func dustLeavesTheSleighWhileItFliesAndBurnsOutBehindIt() throws {
        let page = Self.tv
        #expect(SantaFlight.sparks(at: 0, in: page).isEmpty)
        let midway = SantaFlight.sparks(at: 5, in: page)
        #expect(midway.count > 20)
        // Behind the sleigh, never ahead of it.
        let sleigh = SantaFlight.sleighX(at: 5, in: page)
        #expect(midway.allSatisfy { $0.center.x < sleigh })
        #expect(midway.allSatisfy { (0...1).contains($0.opacity) && $0.radius > 0 })
        #expect(midway.contains { $0.isStar } && midway.contains { !$0.isStar })
        // Every mote is spent by the end of the show.
        #expect(SantaFlight.sparks(at: SantaFlight.duration, in: page).isEmpty)
        #expect(SantaFlight.dust.allSatisfy { $0.born >= 0 && $0.born <= SantaFlight.crossing })
        #expect(SantaFlight.dust.allSatisfy { SantaFlight.dustLife.contains($0.life) })
    }

    @Test func aMoteFallsAndFadesAsItAges() throws {
        let page = Self.tv
        let mote = try #require(SantaFlight.dust.first { $0.born > 2 && $0.life > 2.5 })
        func spark(aged age: Double) -> SantaFlight.Spark? {
            let alight = SantaFlight.sparks(at: mote.born + age, in: page)
            let index = SantaFlight.dust.filter { other in
                let otherAge = mote.born + age - other.born
                return otherAge > 0 && otherAge < other.life
            }.firstIndex(of: mote)
            return index.map { alight[$0] }
        }
        let young = try #require(spark(aged: 0.3))
        let old = try #require(spark(aged: mote.life - 0.2))
        #expect(old.center.y > young.center.y)
        #expect(old.radius < young.radius)
        #expect(spark(aged: mote.life + 0.01) == nil)
    }

    @Test func theSameSeedScattersTheSameDust() {
        #expect(SantaFlight.motes(count: 40, seed: 9) == SantaFlight.motes(count: 40, seed: 9))
        #expect(SantaFlight.motes(count: 40, seed: 9) != SantaFlight.motes(count: 40, seed: 10))
    }

    @Test func theReinsRunFromTheDriversHandToEachNearReindeer() {
        let page = Self.tv
        let corners = SantaFlight.reinPoints(at: 4, in: page)
        #expect(corners.count == 1 + SantaFlight.pairs.count)
        // Forward along the team, the lead's collar last.
        #expect(zip(corners, corners.dropFirst()).allSatisfy { $0.x < $1.x })
        let sleigh = SantaFlight.sleighX(at: 4, in: page)
        #expect(corners[0].x > sleigh)
        #expect(corners[0].x < sleigh + 60 * SantaFlight.scale(in: page))
    }

    @Test func theTeamIsThreePairsAndTheSleighDrawnOverThem() {
        let team = SantaFlight.team
        #expect(team.map(\.kind) == [.far, .near, .far, .near, .far, .near, .sleigh])
        #expect(team.filter(\.isLead).count == 1)
        #expect(team.last(where: { $0.kind == .near })?.isLead == true)
        // No two reindeer run in step.
        #expect(Set(team.filter { $0.kind != .sleigh }.map(\.phase)).count == 6)
    }

    @Test func thePageDimsAsTheSleighArrivesAndClearsWithTheLastDust() {
        #expect(SantaFlight.presence(at: 0) == 0)
        #expect(SantaFlight.presence(at: 0.5) == 0.5)
        #expect(SantaFlight.presence(at: SantaFlight.crossing / 2) == 1)
        #expect(SantaFlight.presence(at: SantaFlight.duration) == 0)
        #expect(SantaFlight.presence(at: SantaFlight.duration + 5) == 0)
        #expect(SantaFlight.stillMoment > 1 && SantaFlight.stillMoment < SantaFlight.crossing)
    }
}
