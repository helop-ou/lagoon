import Foundation
import Testing
@testable import Lagoon

@Suite("New Year surprise")
@MainActor
struct NewYearTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Tallinn")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    /// Noon, so the store's own calendar agrees on the day in any time zone
    /// the tests run in.
    private static func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day, hour: 12
        ))!
    }

    private func defaults() -> UserDefaults {
        let suite = "NewYearTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func theNewYearIsWelcomedAllThroughTheFirstOfJanuaryOnly() {
        let calendar = Self.calendar
        #expect(NewYear.year(on: Self.date(2026, 12, 31, 23, 59, 59), calendar: calendar) == nil)
        #expect(NewYear.year(on: Self.date(2027, 1, 1, 0, 0, 0), calendar: calendar) == 2027)
        #expect(NewYear.year(on: Self.date(2027, 1, 1, 23, 59, 59), calendar: calendar) == 2027)
        #expect(NewYear.year(on: Self.date(2027, 1, 2, 0, 0, 0), calendar: calendar) == nil)
        #expect(NewYear.year(on: Self.date(2027, 7, 1), calendar: calendar) == nil)
    }

    @Test func midnightIsCountedDownOnNewYearsEveOnly() {
        let calendar = Self.calendar
        #expect(NewYear.secondsUntilMidnight(from: Self.date(2026, 12, 31, 23, 59, 30), calendar: calendar) == 30)
        #expect(NewYear.secondsUntilMidnight(from: Self.date(2026, 12, 31, 0, 0, 0), calendar: calendar) == 86_400)
        #expect(NewYear.secondsUntilMidnight(from: Self.date(2026, 12, 30, 23, 59, 30), calendar: calendar) == nil)
        #expect(NewYear.secondsUntilMidnight(from: Self.date(2027, 1, 1, 0, 0, 0), calendar: calendar) == nil)
    }

    @Test func aProfileSeesTheFireworksOnceAYear() {
        let defaults = defaults()
        var today = Self.noon(2026, 12, 31)
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "a")
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 0)

        today = Self.noon(2027, 1, 1)
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 1)
        // Not again that day, however often Lagoon comes back.
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 1)
        // Another profile has its own, and the first is still done.
        store.configure(accountID: "b")
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 2)
        store.configure(accountID: "a")
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 2)

        // A day late is too late, and next year it comes again.
        today = Self.noon(2027, 1, 2)
        store.configure(accountID: "c")
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 2)
        today = Self.noon(2028, 1, 1)
        store.configure(accountID: "a")
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 3)
    }

    @Test func aProfileThatTurnedTheSeasonsOffGetsNoFireworks() {
        let store = ThemeStore(defaults: defaults(), now: { Self.noon(2027, 1, 1) })
        store.configure(accountID: "a")
        store.setFollowsSeasons(false)
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 0)
        // Turned back on that day, they are still owed.
        store.setFollowsSeasons(true)
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 1)
    }

    @Test func nobodySignedInGetsNoFireworksAndUsesNobodysTurn() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, now: { Self.noon(2027, 1, 1) })
        store.welcomeNewYearIfDue()
        #expect(store.newYearCount == 0)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(ThemeStore.newYearKeyPrefix) })
    }

    @Test func forgettingAnAccountForgetsItsNewYearToo() {
        #expect(AccountLocalData.perAccountKeyPrefixes.contains(ThemeStore.newYearKeyPrefix))
    }

    @Test func theGreetingNamesTheYearBeingWelcomed() {
        let calendar = Self.calendar
        #expect(NewYear.upcomingYear(on: Self.date(2027, 1, 1, 0, 0, 5), calendar: calendar) == 2027)
        #expect(NewYear.upcomingYear(on: Self.date(2026, 12, 31, 23, 59, 59), calendar: calendar) == 2027)
        #expect(NewYear.upcomingYear(on: Self.date(2026, 11, 16), calendar: calendar) == 2027)
    }

    // MARK: - The show

    private static let page = CGSize(width: 400, height: 800)

    private func shell(_ kind: Fireworks.Kind, sparks: [Fireworks.Spark]) -> Fireworks.Shell {
        // Launched so that it bursts at zero, which keeps the moments below exact.
        Fireworks.Shell(launch: -Fireworks.climb, lane: 0.5, apex: 0.4, reach: 0.25, tint: 0, kind: kind, sparks: sparks)
    }

    @Test func theShowOpensWithOneShellBuildsAndEndsInAVolley() throws {
        let show = Fireworks.show(tints: 4, seed: 2027)
        #expect(show == Fireworks.show(tints: 4, seed: 2027))
        #expect(show != Fireworks.show(tints: 4, seed: 2028))
        #expect(show.count == 21)
        #expect(Set(show.map(\.tint)) == [0, 1, 2, 3])
        #expect(Set(show.map(\.kind)).count == Fireworks.Kind.allCases.count)
        func bursts(_ shell: Fireworks.Shell) -> Double { shell.launch + Fireworks.climb }
        // One big shell in the middle before anything else.
        let opening = try #require(show.first)
        #expect(abs(bursts(opening) - 1.4) < 0.0001 && opening.lane == 0.5)
        #expect(show.dropFirst().allSatisfy { bursts($0) > bursts(opening) })
        #expect(opening.reach >= show.dropFirst().prefix(11).map(\.reach).max() ?? 1)
        // Nine shells inside a second and a half, right across the page.
        let volley = show.filter { bursts($0) >= Fireworks.finale - 0.0001 }
        #expect(volley.count == 9)
        #expect(volley.allSatisfy { bursts($0) <= Fireworks.finale + 1.3001 })
        let lanes = volley.map(\.lane)
        #expect(Set(lanes).count == 9)
        #expect((lanes.max() ?? 0) - (lanes.min() ?? 0) >= 0.79)
        // Nothing is still burning when the show ends, and none leaves before it starts.
        for shell in show {
            #expect(shell.launch >= 0)
            #expect(bursts(shell) + shell.kind.burn <= Fireworks.duration)
        }
    }

    @Test func aShellClimbsFromTheGroundThenFlashesWhereItStopped() throws {
        let page = Self.page
        let shell = Fireworks.Shell(
            launch: 0, lane: 0.25, apex: 0.3, reach: 0.25, tint: 0, kind: .ring,
            sparks: [Fireworks.Spark(angle: 0, speed: 1, flicker: 0)]
        )
        // Nothing before it leaves the ground.
        #expect(Fireworks.rocket(of: shell, at: -0.1, in: page) == nil)
        #expect(Fireworks.burst(of: shell, at: -0.1, in: page) == nil)
        let leaving = try #require(Fireworks.rocket(of: shell, at: 0, in: page))
        #expect(leaving.to == CGPoint(x: 100, y: 800))
        let arriving = try #require(Fireworks.rocket(of: shell, at: Fireworks.climb - 0.001, in: page))
        #expect(abs(arriving.to.y - 240) < 1)
        #expect(arriving.from.y > arriving.to.y)
        #expect(Fireworks.burst(of: shell, at: Fireworks.climb - 0.001, in: page) == nil)
        #expect(Fireworks.flash(of: shell, at: Fireworks.climb - 0.001, in: page) == nil)

        // The rocket ends in a flash at the apex, which swells and is gone.
        #expect(Fireworks.rocket(of: shell, at: Fireworks.climb, in: page) == nil)
        let flash = try #require(Fireworks.flash(of: shell, at: Fireworks.climb, in: page))
        #expect(flash.center == CGPoint(x: 100, y: 240))
        #expect(flash.opacity == 1)
        let later = try #require(Fireworks.flash(of: shell, at: Fireworks.climb + Fireworks.flashTime / 2, in: page))
        #expect(later.radius > flash.radius && later.opacity < 0.5)
        #expect(Fireworks.flash(of: shell, at: Fireworks.climb + Fireworks.flashTime, in: page) == nil)
    }

    @Test func aBurstFliesOutTrailsDroopsAndBurnsOut() throws {
        let page = Self.page
        let center = CGPoint(x: 200, y: 320)
        let reach = 100.0
        // One spark flying level, one at half the speed.
        let shell = shell(.ring, sparks: [
            Fireworks.Spark(angle: 0, speed: 1, flicker: 0), Fireworks.Spark(angle: .pi, speed: 0.5, flicker: 0),
        ])
        let first = try #require(Fireworks.burst(of: shell, at: 0, in: page))
        #expect(first.opacity == 1)
        #expect(first.trails.count == 2)
        #expect(first.trails.allSatisfy { $0.count == Fireworks.tailPoints })
        #expect(first.trails.allSatisfy { abs($0[3].x - center.x) < 0.001 && abs($0[3].y - center.y) < 0.001 })

        // Early on: outward, the head ahead of its tail.
        let early = try #require(Fireworks.burst(of: shell, at: 0.4, in: page))
        let head = early.trails[0][3], tail = early.trails[0][0]
        #expect(head.x > tail.x && tail.x > center.x)
        #expect(zip(early.trails[0], early.trails[0].dropFirst()).allSatisfy { $0.x < $1.x })
        // The slower spark has gone half as far the other way.
        #expect(abs((center.x - early.trails[1][3].x) * 2 - (head.x - center.x)) < 0.001)

        // Near the end, at a moment its glitter has it alight: almost at full
        // reach, and drooped below the centre.
        let burn = Fireworks.Kind.ring.burn
        let late = try #require(stride(from: burn - 0.02, to: burn - 0.3, by: -0.01).first {
            Fireworks.isLit(shell.sparks[0], at: $0)
        })
        let dying = try #require(Fireworks.burst(of: shell, at: late, in: page))
        let lit = try #require(dying.trails.first { $0[3].x > center.x })
        #expect(lit[3].x > center.x + reach * 0.97 && lit[3].x <= center.x + reach)
        #expect(lit[3].y > center.y + reach * Fireworks.Kind.ring.droop * 0.7)
        #expect(dying.opacity < 0.4)
        // All but out as it ends, then gone.
        #expect((Fireworks.burst(of: shell, at: burn - 0.001, in: page)?.opacity ?? 1) < 0.01)
        #expect(Fireworks.burst(of: shell, at: burn, in: page) == nil)
    }

    @Test func aWillowHangsLongerFallsFurtherAndTrailsMoreThanAPeony() {
        #expect(Fireworks.Kind.willow.burn > Fireworks.Kind.peony.burn)
        #expect(Fireworks.Kind.willow.droop > Fireworks.Kind.peony.droop * 2)
        #expect(Fireworks.Kind.willow.tail > Fireworks.Kind.chrysanthemum.tail)
        #expect(Fireworks.Kind.chrysanthemum.tail > Fireworks.Kind.peony.tail)
    }

    @Test func dyingSparksGlitterEachOnItsOwnBeat() throws {
        let page = Self.page
        let sparks = (0..<60).map { Fireworks.Spark(angle: Double($0) / 10, speed: 1, flicker: Double($0) / 60) }
        let shell = shell(.peony, sparks: sparks)
        let burn = Fireworks.Kind.peony.burn
        // Every spark is alight until the glitter starts.
        let steady = try #require(Fireworks.burst(of: shell, at: burn * Fireworks.glitterFrom - 0.01, in: page))
        #expect(steady.trails.count == 60)
        // Then some are dark at any moment, and not the same ones a moment later.
        let moment = burn * 0.8
        let one = try #require(Fireworks.burst(of: shell, at: moment, in: page))
        #expect(one.trails.count > 15 && one.trails.count < 50)
        let litNow = sparks.map { Fireworks.isLit($0, at: moment) }
        let litNext = sparks.map { Fireworks.isLit($0, at: moment + 0.08) }
        #expect(litNow != litNext)
        // One spark holds its state for a whole beat, a fourteenth of a
        // second, so it does not shimmer every frame. Over many beats it is
        // lit about half the time.
        let spark = Fireworks.Spark(angle: 0, speed: 1, flicker: 0)
        #expect(Fireworks.isLit(spark, at: 1.01) == Fireworks.isLit(spark, at: 1.06))
        let beats = (0..<56).map { Fireworks.isLit(spark, at: (Double($0) + 0.5) / 14) }
        #expect(beats.filter { $0 }.count > 14 && beats.filter { $0 }.count < 42)
    }

    @Test func theShowFadesInAndOutAndTheStillPictureIsAFullMoment() {
        #expect(Fireworks.presence(at: 0) == 0)
        #expect(Fireworks.presence(at: 3) == 1)
        #expect(Fireworks.presence(at: Fireworks.duration) == 0)
        #expect(Fireworks.presence(at: -1) == 0 && Fireworks.presence(at: Fireworks.duration + 1) == 0)
        // The still picture is the closing volley in the air.
        let show = Fireworks.show(tints: 4, seed: 2027)
        let burning = show.filter { Fireworks.burst(of: $0, at: Fireworks.stillMoment, in: Self.page) != nil }
        #expect(burning.count >= 6)
    }

    // MARK: - The greeting

    @Test func theNumeralsPopInOneAfterAnotherAndStandStillWithoutAClock() {
        // Small before its turn, past full size on the way, then settled.
        #expect(NewYearGreeting.pop(since: 2, at: 1.9) == 0.4)
        #expect(NewYearGreeting.pop(since: 2, at: 2) == 0.4)
        let sizes = stride(from: 2.0, through: 3.2, by: 0.02).map { NewYearGreeting.pop(since: 2, at: $0) }
        #expect((sizes.max() ?? 0) > 1.05)
        #expect(abs(NewYearGreeting.pop(since: 2, at: 3.2) - 1) < 0.001)
        // Invisible until its turn, then quickly there.
        #expect(NewYearGreeting.rise(since: 2, at: 1.99, over: 0.12) == 0)
        #expect(NewYearGreeting.rise(since: 2, at: 2.2, over: 0.12) == 1)
        // Reduce Motion: full size, fully there.
        #expect(NewYearGreeting.pop(since: 2, at: nil) == 1)
        #expect(NewYearGreeting.rise(since: 2, at: nil, over: 0.12) == 1)
        // The greeting waits for the opening burst and is gone before the show ends.
        #expect(NewYearGreeting.arrives > 1.4 && NewYearGreeting.leaves < Fireworks.duration)
    }

    @Test func aShineCrossesTheNumeralsNowAndThenAndNeverStandingStill() {
        let start = NewYearGreeting.arrives + 0.8
        #expect(NewYearGreeting.shinePosition(at: start - 0.01) == -1)
        let entering = NewYearGreeting.shinePosition(at: start)
        let midway = NewYearGreeting.shinePosition(at: start + 0.55)
        let leaving = NewYearGreeting.shinePosition(at: start + 1.09)
        #expect(entering < 0 && entering > -0.5)
        #expect(abs(midway - 0.5) < 0.01)
        #expect(leaving > 1.2)
        // Dark between two shines, back for the finale, and off without a clock.
        #expect(NewYearGreeting.shinePosition(at: start + 1.2) == -1)
        #expect(NewYearGreeting.shinePosition(at: Fireworks.finale + 1) > 0)
        #expect(NewYearGreeting.shinePosition(at: nil) == -1)
    }

    @Test func starsRingTheNumeralsAndKeepClearOfTheirMiddle() {
        let stars = NewYearGreeting.scatter(count: 16, seed: 31)
        #expect(stars.count == 16)
        #expect(stars == NewYearGreeting.scatter(count: 16, seed: 31))
        // Outside an ellipse about the numerals, on every side of them.
        #expect(stars.allSatisfy { pow($0.offset.x / 1.55, 2) + pow($0.offset.y / 0.78, 2) >= 0.85 * 0.85 - 0.0001 })
        #expect(stars.contains { $0.offset.x < -1 } && stars.contains { $0.offset.x > 1 })
        #expect(stars.contains { $0.offset.y < -0.5 } && stars.contains { $0.offset.y > 0.5 })
        // A star has four points: as wide as it is tall, and thin at the waist.
        let star = NewYearGreeting.star(at: CGPoint(x: 50, y: 50), radius: 10)
        #expect(star.boundingRect == CGRect(x: 40, y: 40, width: 20, height: 20))
        #expect(star.contains(CGPoint(x: 50, y: 42)) && star.contains(CGPoint(x: 58, y: 50)))
        #expect(!star.contains(CGPoint(x: 55, y: 45)))
    }
}
