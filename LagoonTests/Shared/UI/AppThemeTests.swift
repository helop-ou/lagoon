import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("App theme")
@MainActor
struct AppThemeTests {
    /// Mid-month, so no time zone moves them across a month boundary.
    nonisolated static let september = date(2026, 9, 15)
    nonisolated static let october = date(2026, 10, 15)

    nonisolated private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day, hour: 12
        ))!
    }

    private func defaults() -> UserDefaults {
        let suite = "AppThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func themeFollowsTheProfile() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, now: { Self.september })
        store.configure(accountID: "server|partner")
        store.select(.babyPink)
        #expect(store.theme == .babyPink)

        store.configure(accountID: "server|me")
        #expect(store.theme == .lagoon)

        store.configure(accountID: "server|partner")
        #expect(store.theme == .babyPink)
        #expect(defaults.string(forKey: ThemeStore.key("server|partner")) == "babyPink")
        #expect(defaults.string(forKey: ThemeStore.key("server|me")) == nil)
    }

    @Test func aChoiceBloomsButLoadingAtLaunchDoesNot() {
        let store = ThemeStore(defaults: defaults(), now: { Self.september })
        store.configure(accountID: "a")
        #expect(store.bloomCount == 0)
        store.select(.babyPink)
        #expect(store.bloomCount == 1)
        store.select(.babyPink)
        #expect(store.bloomCount == 1)
    }

    @Test func switchingToAnotherProfileBloomsInItsTheme() {
        let defaults = defaults()
        defaults.set("babyPink", forKey: ThemeStore.key("b"))
        let store = ThemeStore(defaults: defaults, now: { Self.september })
        store.configure(accountID: "a")
        store.configure(accountID: "b")
        #expect(store.theme == .babyPink)
        #expect(store.bloomCount == 1)
        // Through the picker's nil, too.
        store.configure(accountID: nil)
        store.configure(accountID: "a")
        #expect(store.theme == .lagoon)
        #expect(store.bloomCount == 2)
    }

    @Test func returningToTheSameProfileDoesNotBloom() {
        let store = ThemeStore(defaults: defaults(), now: { Self.september })
        store.configure(accountID: "a")
        store.configure(accountID: nil)
        store.configure(accountID: "a")
        #expect(store.bloomCount == 0)
    }

    @Test func noAccountMeansTheBrandThemeAndNothingSaved() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, now: { Self.september })
        store.configure(accountID: nil)
        store.select(.babyPink)
        #expect(store.theme == .babyPink)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(ThemeStore.keyPrefix) })
        store.configure(accountID: "a")
        #expect(store.theme == .lagoon)
    }

    @Test func aStrayStoreCannotDetachTheOwnersProfile() {
        let defaults = defaults()
        defaults.set("babyPink", forKey: ThemeStore.key("a"))
        let store = ThemeStore(defaults: defaults, now: { Self.september })
        let ownerObject = NSObject(), strayObject = NSObject()
        let owner = ObjectIdentifier(ownerObject), stray = ObjectIdentifier(strayObject)
        store.configure(accountID: "a", owner: owner)
        #expect(store.theme == .babyPink)
        store.configure(accountID: nil, owner: stray)
        #expect(store.accountID == "a")
        store.select(.lagoon)
        #expect(defaults.string(forKey: ThemeStore.key("a")) == "lagoon")
        store.configure(accountID: nil, owner: owner)
        #expect(store.accountID == nil)
    }

    @Test func nobodyActiveKeepsTheLastProfilesThemeUntilAnotherSignsIn() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, now: { Self.september })
        store.configure(accountID: "partner")
        store.select(.babyPink)
        store.configure(accountID: nil)
        #expect(store.theme == .babyPink)
        // A choice made with nobody active is not anybody's.
        store.select(.lagoon)
        #expect(defaults.string(forKey: ThemeStore.key("partner")) == "babyPink")
        store.configure(accountID: "me")
        #expect(store.theme == .lagoon)
        store.configure(accountID: nil)
        store.configure(accountID: "partner")
        #expect(store.theme == .babyPink)
    }

    @Test func anUnknownSavedThemeFallsBackToTheBrand() {
        let defaults = defaults()
        defaults.set("neon", forKey: ThemeStore.key("a"))
        #expect(ThemeStore.storedTheme(for: "a", in: defaults) == .lagoon)
        defaults.set("babyPink", forKey: ThemeStore.key("a"))
        #expect(ThemeStore.storedTheme(for: "a", in: defaults) == .babyPink)
    }

    /// The picker lists every case, and a saved choice is the case's name on
    /// disk: renaming one forgets every profile that chose it.
    @Test func savedThemeNamesNeverChange() {
        #expect(AppTheme.allCases.map(\.rawValue) == ["lagoon", "babyPink", "spooky", "winter"])
        let defaults = defaults()
        defaults.set("winter", forKey: ThemeStore.key("a"))
        #expect(ThemeStore.storedTheme(for: "a", in: defaults) == .winter)
    }

    /// Posters keep their own colours under the brand, Baby Pink and Winter.
    @Test func artworkGlowsAreLeftAloneByTheBrandPinkAndWinter() {
        let artwork = ArtworkPalette(colors: [.red, .green, .blue])
        #expect(AppTheme.lagoon.palette.glow(for: artwork) == artwork)
        #expect(AppTheme.babyPink.palette.glow(for: artwork) == artwork)
        #expect(AppTheme.winter.palette.glow(for: artwork) == artwork)
    }

    @Test func spookyBlushesArtworkGlows() {
        let artwork = ArtworkPalette(colors: [.red, .green])

        #expect(AppTheme.spooky.palette.glow(for: artwork) != artwork)
    }

    @Test func aGhostFitsItsRectAndItsFaceIsCutOut() {
        let rect = CGRect(x: 10, y: 20, width: 50, height: 60)
        for wave in stride(from: 0.0, through: 6.3, by: 0.7) {
            let bounds = GhostGeometry.path(in: rect, wave: wave).boundingRect
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "wave \(wave)")
        }
        let ghost = GhostGeometry.path(in: rect)
        // The body is filled. An eye is a hole in it. Probed off the eyes'
        // centre line, where the ellipses' curve joints sit and the
        // containment test miscounts crossings.
        #expect(ghost.contains(CGPoint(x: rect.minX + 25, y: rect.minY + 12), eoFill: true))
        #expect(!ghost.contains(CGPoint(x: rect.minX + 16, y: rect.minY + 22), eoFill: true))
    }

    @Test func aSnowflakeHasSixArmsThatReachItsRadius() {
        let radius = 40.0
        let flake = SnowflakeGeometry.path(radius: radius)
        let bounds = flake.boundingRect
        // An arm points straight up and another straight down. The four
        // between them lean 60 degrees, so they stop short of the sides.
        #expect(abs(bounds.minY + radius) < 0.01 && abs(bounds.maxY - radius) < 0.01)
        #expect(abs(bounds.width - 2 * radius * sin(.pi / 3)) < 0.01)
        // A sixth of a turn lands every arm on its neighbour.
        let turned = flake.applying(CGAffineTransform(rotationAngle: .pi / 3)).boundingRect
        #expect(abs(turned.width - bounds.width) < 0.01 && abs(turned.height - bounds.height) < 0.01)
        // Each arm carries side branches, which stop short of the next arm.
        let inked = flake.strokedPath(SnowflakeGeometry.strokeStyle(radius: radius))
        #expect(inked.contains(CGPoint(x: 6, y: -21.5)))
        #expect(!inked.contains(CGPoint(x: 14, y: -26)))
    }

    @Test func theSameSeedGivesTheSameSnow() {
        let flakes = Snowfall.flakes(count: 40, seed: 5)
        #expect(flakes.count == 40)
        #expect(flakes == Snowfall.flakes(count: 40, seed: 5))
        #expect(flakes != Snowfall.flakes(count: 40, seed: 6))
        #expect(flakes.allSatisfy { (0...1).contains($0.lane) && (0...1).contains($0.depth) })
        // Spread over the page and through the fall, not bunched together.
        #expect(Set(flakes.map { Int($0.lane * 4) }).count == 4)
        #expect(Set(flakes.map { Int($0.start * 4) }).count == 4)
    }

    @Test func aFlakeFallsFromAboveThePageToBelowItAndStartsAgain() {
        let page = CGSize(width: 400, height: 800)
        let radius = 1.0...3.0
        let flake = Snowfall.Flake(lane: 0.5, start: 0, depth: 1, phase: 0)
        let seconds = Snowfall.fall.lowerBound
        // Wholly above the page as it starts, and wholly below as it ends.
        let entering = Snowfall.pose(of: flake, at: 0, in: page, radius: radius)
        #expect(entering.center.y + entering.radius <= 0)
        let leaving = Snowfall.pose(of: flake, at: seconds * 0.9999, in: page, radius: radius)
        #expect(leaving.center.y - leaving.radius > page.height - 1)
        // Down all the way, never up.
        var last = entering.center.y
        for step in 1..<100 {
            let y = Snowfall.pose(of: flake, at: seconds * Double(step) / 100, in: page, radius: radius).center.y
            #expect(y > last, "step \(step)")
            last = y
        }
        // Then from the top again.
        let again = Snowfall.pose(of: flake, at: seconds * 1.25, in: page, radius: radius)
        let before = Snowfall.pose(of: flake, at: seconds * 0.25, in: page, radius: radius)
        #expect(abs(again.center.y - before.center.y) < 0.001)
        // It sways about its lane without leaving it far behind.
        for step in 0..<100 {
            let x = Snowfall.pose(of: flake, at: Double(step) * 0.37, in: page, radius: radius).center.x
            #expect(abs(x - 200) <= 9.001, "step \(step)")
        }
    }

    @Test func aNearFlakeIsBiggerBrighterAndFasterThanAFarOne() {
        let page = CGSize(width: 400, height: 800)
        let radius = 1.0...3.0
        let far = Snowfall.Flake(lane: 0.2, start: 0.3, depth: 0, phase: 0)
        let near = Snowfall.Flake(lane: 0.2, start: 0.3, depth: 1, phase: 0)
        let farPose = Snowfall.pose(of: far, at: 0, in: page, radius: radius)
        let nearPose = Snowfall.pose(of: near, at: 0, in: page, radius: radius)
        #expect(farPose.radius == 1 && nearPose.radius == 3)
        #expect(farPose.opacity == Snowfall.opacity.lowerBound && nearPose.opacity == Snowfall.opacity.upperBound)
        func fallen(_ flake: Snowfall.Flake) -> Double {
            Snowfall.pose(of: flake, at: 1, in: page, radius: radius).center.y
                - Snowfall.pose(of: flake, at: 0, in: page, radius: radius).center.y
        }
        #expect(fallen(near) > fallen(far) * 1.5)
    }

    @Test func onlyWinterSnows() {
        #expect(AppTheme.allCases.filter(\.isSnowy) == [.winter])
    }

    @Test func aCobwebStaysInItsCornerAndEachCornerDiffers() {
        let left = CobwebGeometry.web(size: 100, seed: 3)
        let bounds = left.threads.boundingRect.union(left.spiral.boundingRect)
        #expect(bounds.minX >= -0.01 && bounds.minY >= -0.01)
        #expect(bounds.maxX <= 100.01 && bounds.maxY <= 100.01)
        // The hub sits out from the corner, and both spiders stay on the web.
        #expect(left.hub.x > 15 && left.hub.y > 15)
        #expect(bounds.contains(left.onSteepRadial(0.3)))
        #expect(bounds.contains(left.onSteepRadial(1)))
        #expect(left.steep.y > left.hub.y)
        // Same seed, same web. Another seed, another web.
        #expect(CobwebGeometry.web(size: 100, seed: 3).spiral.description == left.spiral.description)
        #expect(CobwebGeometry.web(size: 100, seed: 11).spiral.description != left.spiral.description)
    }

    @Test func aSpiderIsAboutAsBigAsItsBox() {
        let head = CGPoint(x: 50, y: 50)
        let spider = SpiderGeometry.legs(at: head, size: 20).boundingRect
            .union(SpiderGeometry.body(at: head, size: 20).boundingRect)
        #expect(spider.width > 20 && spider.width < 28)
        #expect(spider.height > 18 && spider.height < 26)
        #expect(spider.contains(SpiderGeometry.marking(at: head, size: 20).boundingRect))
    }

    @Test func theHangingSpiderRestsLowersPausesAndClimbs() {
        let period = 20.0
        #expect(SpiderDrop.reach(at: 2, period: period) == 0)
        #expect(SpiderDrop.reach(at: 7.5, period: period) > 0.4)
        #expect(SpiderDrop.reach(at: 7.5, period: period) < 0.6)
        #expect(SpiderDrop.reach(at: 11, period: period) == 1)
        #expect(SpiderDrop.reach(at: 42, period: period) == 0)
        // Never a jump: a thirtieth of a second moves it only a little.
        for step in 0..<600 {
            let time = Double(step) / 30
            let change = abs(SpiderDrop.reach(at: time + 1.0 / 30, period: period) - SpiderDrop.reach(at: time, period: period))
            #expect(change < 0.02, "at \(time)")
        }
    }

    @Test func ghostsFlyMoreOftenAfterDarkAndInAFlockOnHalloweenNight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Tallinn"))
        func date(_ month: Int, _ day: Int, _ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
        }
        var random = SeededGenerator(seed: 7)

        let day = GhostFlight.plan(at: try date(10, 12, 14), calendar: calendar, using: &random)
        #expect(day.ghosts.count == 1)
        #expect(GhostFlight.dayWait.contains(day.wait))

        let night = GhostFlight.plan(at: try date(10, 12, 22), calendar: calendar, using: &random)
        #expect(night.ghosts.count == 1)
        #expect(GhostFlight.nightWait.contains(night.wait))

        for (month, dayOfMonth, hour) in [(10, 31, 18), (11, 1, 2)] {
            let halloween = GhostFlight.plan(at: try date(month, dayOfMonth, hour), calendar: calendar, using: &random)
            #expect(halloween.ghosts.count == 3)
            #expect(GhostFlight.halloweenWait.contains(halloween.wait))
            #expect(Set(halloween.ghosts.map(\.leftward)).count == 1)
        }
        #expect(!GhostFlight.isHalloweenNight(try date(10, 31, 12), calendar: calendar))
        #expect(!GhostFlight.isHalloweenNight(try date(11, 1, 9), calendar: calendar))
    }

    @Test func aGhostEntersAndLeavesOffThePage() {
        let page = CGSize(width: 1000, height: 600)
        let ghost = GhostFlight.Ghost(lane: 0.4, leftward: false, start: 2, scale: 1, phase: 0)
        #expect(GhostFlight.pose(of: ghost, elapsed: 1, crossing: 10, in: page, height: 100) == nil)
        #expect(GhostFlight.pose(of: ghost, elapsed: 13, crossing: 10, in: page, height: 100) == nil)
        let entering = GhostFlight.pose(of: ghost, elapsed: 2, crossing: 10, in: page, height: 100)
        let leaving = GhostFlight.pose(of: ghost, elapsed: 12, crossing: 10, in: page, height: 100)
        // Its centre is at least half a ghost off either side.
        #expect((entering?.center.x ?? 0) <= -50)
        #expect((leaving?.center.x ?? 0) >= 1050)
        #expect(entering?.opacity == 0)
        #expect(GhostFlight.pose(of: ghost, elapsed: 7, crossing: 10, in: page, height: 100)?.opacity == 1)
        let backwards = GhostFlight.Ghost(lane: 0.4, leftward: true, start: 0, scale: 1, phase: 0)
        #expect((GhostFlight.pose(of: backwards, elapsed: 0, crossing: 10, in: page, height: 100)?.center.x ?? 0) >= 1050)
        let plan = GhostFlight.Plan(wait: 0, ghosts: [ghost, backwards])
        #expect(GhostFlight.duration(of: plan, crossing: 10) == 12)
    }

    // MARK: - October

    @Test func aProfileOnTheDefaultWearsSpookyThroughOctoberOnly() {
        #expect(AppTheme.seasonal(on: Self.october) == .spooky)
        #expect(AppTheme.seasonal(on: Self.september) == nil)
        #expect(AppTheme.seasonal(on: Self.date(2026, 11, 15)) == nil)

        let defaults = defaults()
        var today = Self.october
        let store = ThemeStore(defaults: defaults, now: { today })
        // Never chose, or chose the default before October: both haunted.
        store.configure(accountID: "new")
        #expect(store.theme == .spooky)
        defaults.set("lagoon", forKey: ThemeStore.key("old"))
        store.configure(accountID: "old")
        #expect(store.theme == .spooky)
        // Nothing was saved for them by the season.
        #expect(defaults.string(forKey: ThemeStore.key("new")) == nil)

        today = Self.date(2026, 11, 1)
        store.refreshSeason()
        #expect(store.theme == .lagoon)
    }

    @Test func aChosenThemeIsNeverReplacedBySpooky() {
        let defaults = defaults()
        defaults.set("babyPink", forKey: ThemeStore.key("a"))
        let store = ThemeStore(defaults: defaults, now: { Self.october })
        store.configure(accountID: "a")
        #expect(store.theme == .babyPink)
    }

    @Test func choosingLagoonInOctoberKeepsItUntilNextOctober() {
        let defaults = defaults()
        var today = Self.october
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "a")
        #expect(store.theme == .spooky)
        store.select(.lagoon)
        #expect(store.theme == .lagoon)
        store.configure(accountID: "b")
        store.configure(accountID: "a")
        #expect(store.theme == .lagoon)

        today = Self.date(2027, 10, 5)
        store.refreshSeason()
        #expect(store.theme == .spooky)
    }

    @Test func choosingSpookyKeepsItAfterOctober() {
        let defaults = defaults()
        var today = Self.october
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "a")
        store.select(.babyPink)
        store.select(.spooky)
        today = Self.date(2026, 11, 20)
        store.refreshSeason()
        #expect(store.theme == .spooky)
    }

    @Test func theSeasonTurningIsNotABloom() {
        var today = Self.september
        let store = ThemeStore(defaults: defaults(), now: { today })
        store.configure(accountID: "a")
        today = Self.october
        store.refreshSeason()
        #expect(store.theme == .spooky)
        #expect(store.bloomCount == 0)
    }

    @Test func forgettingAnAccountForgetsItsSeasonChoiceToo() {
        #expect(AccountLocalData.perAccountKeyPrefixes.contains(ThemeStore.seasonKeyPrefix))
    }

    /// `UnwatchedMark` draws black figures on the signal colour.
    @Test(arguments: AppTheme.allCases)
    func blackFiguresStayReadableOnTheSignal(theme: AppTheme) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(theme.palette.signal).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        #expect((luminance + 0.05) / 0.05 >= 6.7)
    }
}
