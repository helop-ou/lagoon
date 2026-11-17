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
    nonisolated static let november = date(2026, 11, 15)
    nonisolated static let december = date(2026, 12, 15)

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

    /// Posters keep their own colours under the brand and Baby Pink.
    @Test func artworkGlowsAreLeftAloneByTheBrandAndPink() {
        let artwork = ArtworkPalette(colors: [.red, .green, .blue])
        #expect(AppTheme.lagoon.palette.glow(for: artwork) == artwork)
        #expect(AppTheme.babyPink.palette.glow(for: artwork) == artwork)
    }

    /// A warm poster would otherwise turn a night page brown or olive.
    @Test func spookyAndWinterBlushArtworkGlows() {
        let artwork = ArtworkPalette(colors: [.red, .green])

        #expect(AppTheme.spooky.palette.glow(for: artwork) != artwork)
        #expect(AppTheme.winter.palette.glow(for: artwork) != artwork)
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
        let flake = Snowfall.Flake(lane: 0.5, start: 0, depth: 1, phase: 0)
        let seconds = Snowfall.fall.lowerBound
        func pose(_ time: Double) -> Snowfall.Pose {
            Snowfall.pose(of: flake, at: time, in: page, dot: 1...3, crystal: 4...8)
        }
        // Wholly above the page as it starts, and wholly below as it ends.
        let entering = pose(0)
        #expect(entering.center.y + entering.radius <= 0)
        let leaving = pose(seconds * 0.9999)
        #expect(leaving.center.y - leaving.radius > page.height - 1)
        // Down all the way, never up.
        var last = entering.center.y
        for step in 1..<100 {
            let y = pose(seconds * Double(step) / 100).center.y
            #expect(y > last, "step \(step)")
            last = y
        }
        // Then from the top again.
        #expect(abs(pose(seconds * 1.25).center.y - pose(seconds * 0.25).center.y) < 0.001)
        // It sways about its lane without leaving it far behind.
        for step in 0..<100 {
            #expect(abs(pose(Double(step) * 0.37).center.x - 200) <= 12.001, "step \(step)")
        }
    }

    @Test func aNearFlakeIsBiggerBrighterAndFasterThanAFarOne() {
        let page = CGSize(width: 400, height: 800)
        func pose(_ flake: Snowfall.Flake, _ time: Double) -> Snowfall.Pose {
            Snowfall.pose(of: flake, at: time, in: page, dot: 1...3, crystal: 4...8)
        }
        let far = Snowfall.Flake(lane: 0.2, start: 0.3, depth: 0, phase: 0)
        let near = Snowfall.Flake(lane: 0.2, start: 0.3, depth: 1, phase: 0)
        #expect(pose(far, 0).radius == 1 && pose(near, 0).radius == 8)
        #expect(pose(far, 0).opacity == Snowfall.opacity.lowerBound)
        #expect(pose(near, 0).opacity == Snowfall.opacity.upperBound)
        func fallen(_ flake: Snowfall.Flake) -> Double {
            pose(flake, 1).center.y - pose(flake, 0).center.y
        }
        #expect(fallen(near) > fallen(far) * 1.5)
    }

    @Test func aFlakeCloseEnoughIsACrystalThatTurnsAndAFarOneIsASoftDot() {
        let page = CGSize(width: 400, height: 800)
        func pose(depth: Double, at time: Double = 0) -> Snowfall.Pose {
            Snowfall.pose(
                of: Snowfall.Flake(lane: 0.5, start: 0.5, depth: depth, phase: 1),
                at: time, in: page, dot: 1...3, crystal: 4...8
            )
        }
        let dot = pose(depth: Snowfall.crystalDepth - 0.01)
        #expect(!dot.isCrystal)
        #expect(dot.radius > 2.9 && dot.radius < 3)
        // The smallest crystal is already bigger than the biggest dot.
        let smallest = pose(depth: Snowfall.crystalDepth)
        #expect(smallest.isCrystal)
        #expect(smallest.radius == 4)
        #expect(pose(depth: 1).radius == 8)
        // Turning steadily, from where its phase left it.
        #expect(pose(depth: 1).turn == 1)
        #expect(abs(pose(depth: 1, at: 10).turn - (1 + 10 * Snowfall.spin)) < 0.0001)
    }

    @Test func aFlakesFallTimeAndProgressAgreeWithWhereItIsDrawn() {
        let near = Snowfall.Flake(lane: 0.5, start: 0.25, depth: 1, phase: 0)
        let far = Snowfall.Flake(lane: 0.5, start: 0.25, depth: 0, phase: 0)
        #expect(Snowfall.seconds(of: near) == Snowfall.fall.lowerBound)
        #expect(Snowfall.seconds(of: far) == Snowfall.fall.upperBound)
        #expect(Snowfall.progress(of: near, at: 0) == 0.25)
        #expect(abs(Snowfall.progress(of: near, at: Snowfall.fall.lowerBound / 2) - 0.75) < 0.0001)
        // Once round, it is where it started.
        #expect(abs(Snowfall.progress(of: near, at: Snowfall.fall.lowerBound) - 0.25) < 0.0001)
        let pose = Snowfall.pose(of: near, at: 0, in: CGSize(width: 400, height: 800), dot: 1...3, crystal: 4...8)
        #expect(abs(pose.center.y - (-8 + 0.25 * 816)) < 0.0001)
        #expect(Snowfall.swing(isCrystal: true) < Snowfall.swing(isCrystal: false))
    }

    @Test func theMovingSnowIsOneLayerAFlakeSetFallingFromWhereTheClockHasIt() throws {
        let view = SnowfallLayerView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.now = { 100 }
        view.rebuild()
        let flakes = SnowfallFrame.flakes
        #expect(view.flakeLayers.count == flakes.count)
        let crystals = view.flakeLayers.filter { $0 is CAShapeLayer }
        #expect(crystals.count == flakes.filter { $0.depth >= Snowfall.crystalDepth }.count)
        #expect(!crystals.isEmpty && crystals.count < flakes.count)
        for (flake, layer) in zip(flakes, view.flakeLayers) {
            let fall = try #require(layer.animation(forKey: SnowfallLayerView.fallKey) as? CABasicAnimation)
            #expect(fall.duration == Snowfall.seconds(of: flake))
            #expect(fall.repeatCount == .infinity)
            #expect(abs(fall.timeOffset / fall.duration - Snowfall.progress(of: flake, at: 100)) < 0.0001)
            // From wholly above the page to wholly below it.
            let from = try #require(fall.fromValue as? Double)
            let to = try #require(fall.toValue as? Double)
            #expect(from < 0 && to > 800)
            #expect(layer.animation(forKey: SnowfallLayerView.swayKey) != nil)
            // Drawn thirty times a second, whatever the display's rate.
            for key in [SnowfallLayerView.fallKey, SnowfallLayerView.swayKey, SnowfallLayerView.spinKey] {
                guard let animation = layer.animation(forKey: key) else { continue }
                #expect(animation.preferredFrameRateRange.maximum == Motion.snowFramesPerSecond)
                #expect(animation.preferredFrameRateRange.preferred == Motion.snowFramesPerSecond)
            }
            // Only a crystal turns.
            #expect((layer.animation(forKey: SnowfallLayerView.spinKey) != nil) == (layer is CAShapeLayer))
        }
        // Building again replaces the layers. It does not pile them up.
        view.now = { 200 }
        view.rebuild()
        #expect(view.flakeLayers.count == flakes.count)
        #expect(view.layer.sublayers?.count == flakes.count)
    }

    @Test func frostGrowsOutOfTheCornerAlongBothEdgesAndThinsAway() throws {
        let frost = FrostGeometry.frost(size: 100, seed: 3)
        #expect(frost == FrostGeometry.frost(size: 100, seed: 3))
        #expect(frost != FrostGeometry.frost(size: 100, seed: 11))
        // The biggest crystal sits in the corner.
        let corner = try #require(frost.crystals.first)
        #expect(corner.radius == 62)
        #expect(hypot(corner.center.x, corner.center.y) < 10)
        #expect(frost.crystals.dropFirst().allSatisfy { $0.radius < corner.radius })
        // The rest sit on an edge, smaller the further along it they are.
        let top = frost.crystals.dropFirst().filter { $0.center.x > $0.center.y }
        let side = frost.crystals.dropFirst().filter { $0.center.y > $0.center.x }
        #expect(top.count >= 2 && side.count >= 2)
        #expect(top.allSatisfy { abs($0.center.y) <= $0.radius * 0.25 })
        #expect(side.allSatisfy { abs($0.center.x) <= $0.radius * 0.25 })
        #expect(zip(top, top.dropFirst()).allSatisfy { $0.center.x < $1.center.x && $0.radius > $1.radius })
        #expect(zip(side, side.dropFirst()).allSatisfy { $0.center.y < $1.center.y && $0.radius > $1.radius })
        // Specks stay inside the frost, most of them near the corner.
        #expect(frost.specks.count == FrostGeometry.speckCount)
        let distances = frost.specks.map { hypot($0.center.x, $0.center.y) }
        #expect(distances.allSatisfy { $0 <= 100 * FrostGeometry.reach })
        #expect(distances.filter { $0 < 60 }.count > distances.filter { $0 >= 60 }.count)
        #expect(frost.specks.allSatisfy { $0.center.x >= 0 && $0.center.y >= 0 })
        // Full strength in the corner, none where the frost ends.
        #expect(FrostGeometry.strength(at: .zero, size: 100) == 1)
        #expect(abs(FrostGeometry.strength(at: CGPoint(x: 60, y: 0), size: 100) - 0.5) < 0.0001)
        #expect(FrostGeometry.strength(at: CGPoint(x: 0, y: 120), size: 100) == 0)
        #expect(FrostGeometry.strength(at: CGPoint(x: 300, y: 300), size: 100) == 0)
    }

    @Test func aFrostCrystalHasAHeartAndMoreBranchesThanAFallingFlake() {
        let radius = 40.0
        let hairline = StrokeStyle(lineWidth: 1)
        let frost = SnowflakeGeometry.frostPath(radius: radius).strokedPath(hairline)
        let flake = SnowflakeGeometry.path(radius: radius).strokedPath(hairline)
        // Both reach the radius on six arms.
        #expect(abs(SnowflakeGeometry.frostPath(radius: radius).boundingRect.height - 2 * radius) < 0.01)
        // The middle of one side of the hexagon at its heart.
        let heart = CGPoint(x: 2.42, y: -4.2)
        #expect(frost.contains(heart) && !flake.contains(heart))
        // Halfway along a branch near the tip, where a flake's arm is bare.
        let tipBranch = CGPoint(x: 2.08, y: -35.6)
        #expect(frost.contains(tipBranch) && !flake.contains(tipBranch))
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

    // MARK: - Seasons

    @Test func octoberIsSpookyAndWinterRunsFromDecemberToTheSixthOfJanuary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func season(_ year: Int, _ month: Int, _ day: Int) -> ThemeSeason? {
            ThemeSeason.current(on: Self.date(year, month, day), calendar: calendar)
        }
        #expect(season(2026, 9, 30) == nil)
        #expect(season(2026, 10, 1) == ThemeSeason(theme: .spooky, year: 2026))
        #expect(season(2026, 10, 31) == ThemeSeason(theme: .spooky, year: 2026))
        #expect(season(2026, 11, 1) == nil)
        #expect(season(2026, 11, 30) == nil)
        #expect(season(2026, 12, 1) == ThemeSeason(theme: .winter, year: 2026))
        #expect(season(2026, 12, 31) == ThemeSeason(theme: .winter, year: 2026))
        // The same winter on the other side of New Year, and not the next.
        #expect(season(2027, 1, 6) == ThemeSeason(theme: .winter, year: 2026))
        #expect(season(2027, 1, 7) == nil)
        #expect(season(2027, 12, 1)?.id != season(2026, 12, 1)?.id)
    }

    @Test func aNewProfileWearsEachSeasonsThemeAndItsOwnBetweenThem() {
        let defaults = defaults()
        var today = Self.october
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "new")
        #expect(store.followsSeasons)
        #expect(store.theme == .spooky)
        // The season saves nothing of its own.
        #expect(defaults.string(forKey: ThemeStore.key("new")) == nil)

        today = Self.november
        store.refreshSeason()
        #expect(store.theme == .lagoon)
        today = Self.december
        store.refreshSeason()
        #expect(store.theme == .winter)
        today = Self.date(2027, 1, 20)
        store.refreshSeason()
        #expect(store.theme == .lagoon)
    }

    @Test func aChosenThemeGivesWayToTheSeasonAndReturnsAfterIt() {
        let defaults = defaults()
        var today = Self.september
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "a")
        store.select(.babyPink)
        #expect(store.themeAfterSeason == nil)

        today = Self.december
        store.refreshSeason()
        #expect(store.theme == .winter)
        #expect(store.themeAfterSeason == .babyPink)
        #expect(defaults.string(forKey: ThemeStore.key("a")) == "babyPink")

        today = Self.date(2027, 1, 20)
        store.refreshSeason()
        #expect(store.theme == .babyPink)
        #expect(store.themeAfterSeason == nil)
    }

    @Test func aThemeChosenDuringASeasonStaysForItAndTheNextSeasonStillComes() {
        let defaults = defaults()
        var today = Self.october
        let store = ThemeStore(defaults: defaults, now: { today })
        store.configure(accountID: "a")
        #expect(store.theme == .spooky)
        store.select(.lagoon)
        #expect(store.theme == .lagoon)
        // Through a profile switch and the rest of October.
        store.configure(accountID: "b")
        store.configure(accountID: "a")
        #expect(store.theme == .lagoon)
        today = Self.date(2026, 10, 28)
        store.refreshSeason()
        #expect(store.theme == .lagoon)

        // Winter is another season, and so is the next October.
        today = Self.december
        store.refreshSeason()
        #expect(store.theme == .winter)
        today = Self.date(2027, 10, 5)
        store.refreshSeason()
        #expect(store.theme == .spooky)
    }

    @Test func aThemeChosenInDecemberStaysPastNewYearUntilWinterEnds() {
        var today = Self.december
        let store = ThemeStore(defaults: defaults(), now: { today })
        store.configure(accountID: "a")
        store.select(.babyPink)
        today = Self.date(2027, 1, 3)
        store.refreshSeason()
        #expect(store.theme == .babyPink)
        today = Self.date(2027, 12, 15)
        store.refreshSeason()
        #expect(store.theme == .winter)
    }

    @Test func choosingTheSeasonsOwnThemeKeepsItAfterTheSeason() {
        var today = Self.october
        let store = ThemeStore(defaults: defaults(), now: { today })
        store.configure(accountID: "a")
        store.select(.babyPink)
        store.select(.spooky)
        today = Self.november
        store.refreshSeason()
        #expect(store.theme == .spooky)
    }

    @Test func aProfileThatTurnedTheSeasonsOffKeepsItsOwnTheme() {
        var today = Self.september
        let store = ThemeStore(defaults: defaults(), now: { today })
        store.configure(accountID: "a")
        store.setFollowsSeasons(false)
        #expect(!store.followsSeasons)
        today = Self.october
        store.refreshSeason()
        #expect(store.theme == .lagoon)
        today = Self.december
        store.refreshSeason()
        #expect(store.theme == .lagoon)
        // The switch belongs to the profile, like the theme.
        store.configure(accountID: "b")
        #expect(store.followsSeasons)
        #expect(store.theme == .winter)
        store.configure(accountID: "a")
        #expect(!store.followsSeasons)
        #expect(store.theme == .lagoon)
    }

    @Test func turningTheSeasonsOnOrOffDuringOneChangesTheThemeAtOnce() {
        let defaults = defaults()
        defaults.set("babyPink", forKey: ThemeStore.key("a"))
        let store = ThemeStore(defaults: defaults, now: { Self.december })
        store.configure(accountID: "a")
        #expect(store.theme == .winter)

        store.setFollowsSeasons(false)
        #expect(store.theme == .babyPink)
        #expect(store.bloomCount == 1)
        store.setFollowsSeasons(true)
        #expect(store.theme == .winter)
        #expect(store.bloomCount == 2)
        // Asking for what is already so does nothing.
        store.setFollowsSeasons(true)
        #expect(store.bloomCount == 2)

        // On again brings the season back, even after a choice made in it.
        store.select(.lagoon)
        #expect(store.theme == .lagoon)
        store.setFollowsSeasons(false)
        store.setFollowsSeasons(true)
        #expect(store.theme == .winter)
        #expect(store.themeAfterSeason == .lagoon)
    }

    /// Builds before the switch stored a bare year for a declined October.
    @Test func anOctoberDeclinedByAnOlderBuildDoesNotDeclineWinter() {
        let defaults = defaults()
        defaults.set(2026, forKey: ThemeStore.seasonKey("a"))
        let store = ThemeStore(defaults: defaults, now: { Self.december })
        store.configure(accountID: "a")
        #expect(store.theme == .winter)
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

    @Test func forgettingAnAccountForgetsItsSeasonChoicesToo() {
        #expect(AccountLocalData.perAccountKeyPrefixes.contains(ThemeStore.seasonKeyPrefix))
        #expect(AccountLocalData.perAccountKeyPrefixes.contains(ThemeStore.followsSeasonsKeyPrefix))
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
