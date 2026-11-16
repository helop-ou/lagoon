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

    // MARK: - The show

    @Test func theShowIsTheSameEveryTimeAndEveryShellBurnsOutBeforeItEnds() {
        let show = Fireworks.show(shells: 14, tints: 4, seed: 2027)
        #expect(show.count == 14)
        #expect(show == Fireworks.show(shells: 14, tints: 4, seed: 2027))
        #expect(show != Fireworks.show(shells: 14, tints: 4, seed: 2028))
        #expect(Set(show.map(\.tint)) == [0, 1, 2, 3])
        for shell in show {
            #expect(shell.launch >= 0)
            #expect(shell.launch + Fireworks.climb + Fireworks.burn < Fireworks.duration)
        }
        // Launched through the show, not all at once.
        #expect((show.map(\.launch).max() ?? 0) > Fireworks.duration / 2)
    }

    @Test func aShellClimbsFromTheGroundThenBurstsWhereItStopped() throws {
        let page = CGSize(width: 400, height: 800)
        // Launched at zero, so the moments below are exact.
        let shell = Fireworks.Shell(launch: 0, lane: 0.25, apex: 0.3, reach: 0.25, tint: 0, sparks: 12, turn: 0)
        // Nothing before it leaves the ground.
        #expect(Fireworks.rocket(of: shell, at: -0.1, in: page) == nil)
        #expect(Fireworks.sparks(of: shell, at: -0.1, in: page).isEmpty)
        let leaving = try #require(Fireworks.rocket(of: shell, at: 0, in: page))
        #expect(leaving.to == CGPoint(x: 100, y: 800))
        let arriving = try #require(Fireworks.rocket(of: shell, at: Fireworks.climb - 0.001, in: page))
        #expect(abs(arriving.to.y - 240) < 1)
        #expect(arriving.from.y > arriving.to.y)
        #expect(Fireworks.sparks(of: shell, at: Fireworks.climb - 0.001, in: page).isEmpty)

        // The burst starts at the apex as the rocket ends.
        #expect(Fireworks.rocket(of: shell, at: Fireworks.climb, in: page) == nil)
        let first = Fireworks.sparks(of: shell, at: Fireworks.climb, in: page)
        #expect(first.count == 12)
        #expect(first.allSatisfy { abs($0.to.x - 100) < 0.001 && abs($0.to.y - 240) < 0.001 })
        #expect(first.allSatisfy { $0.opacity == 1 })
        // A shell launched later does the same, later.
        let later = Fireworks.Shell(launch: 2, lane: 0.25, apex: 0.3, reach: 0.25, tint: 0, sparks: 12, turn: 0)
        #expect(Fireworks.rocket(of: later, at: 1.9, in: page) == nil)
        #expect(Fireworks.rocket(of: later, at: 2.4, in: page) != nil)
        #expect(Fireworks.sparks(of: later, at: 3.5, in: page).count == 12)
    }

    @Test func aBurstSpreadsInTwoRingsDroopsAndBurnsOut() {
        let page = CGSize(width: 400, height: 800)
        let shell = Fireworks.Shell(launch: 0, lane: 0.5, apex: 0.4, reach: 0.25, tint: 0, sparks: 12, turn: 0)
        let center = CGPoint(x: 200, y: 320)
        let reach = 100.0
        func distances(at age: Double) -> [Double] {
            Fireworks.sparks(of: shell, at: Fireworks.climb + age, in: page).map {
                hypot($0.to.x - center.x, $0.to.y - center.y)
            }
        }
        // Outward all the while, the outer ring to its full reach.
        let early = distances(at: 0.2), late = distances(at: 1.5)
        #expect(zip(early, late).allSatisfy { $0 < $1 })
        let last = Fireworks.sparks(of: shell, at: Fireworks.climb + Fireworks.burn - 0.001, in: page)
        // Spark 0 flies level: full reach across, and drooped below the centre.
        #expect(abs(last[0].to.x - (center.x + reach)) < 0.5)
        #expect(last[0].to.y > center.y + reach * 0.25)
        // Spark 1 belongs to the inner ring.
        let inner = hypot(last[1].to.x - center.x, last[1].to.y - (center.y + reach * 0.3))
        #expect(inner < reach * 0.65 && inner > reach * 0.5)
        // Fading to nothing, then gone.
        #expect(last[0].opacity < 0.01)
        #expect(Fireworks.sparks(of: shell, at: Fireworks.climb + Fireworks.burn, in: page).isEmpty)
    }

    @Test func theShowFadesInAndOutAndTheGreetingComesAndGoesInsideIt() {
        #expect(Fireworks.presence(at: 0) == 0)
        #expect(Fireworks.presence(at: 3) == 1)
        #expect(Fireworks.presence(at: Fireworks.duration) == 0)
        #expect(Fireworks.presence(at: -1) == 0 && Fireworks.presence(at: Fireworks.duration + 1) == 0)
        #expect(Fireworks.greeting(at: 1) == 0)
        #expect(Fireworks.greeting(at: 4) == 1)
        #expect(Fireworks.greeting(at: Fireworks.duration - 0.5) == 0)
        // The still picture is a moment with bursts in the air.
        let show = Fireworks.show(shells: 14, tints: 4, seed: 2027)
        let page = CGSize(width: 400, height: 800)
        let burning = show.filter { !Fireworks.sparks(of: $0, at: Fireworks.stillMoment, in: page).isEmpty }
        #expect(burning.count >= 2)
    }
}
