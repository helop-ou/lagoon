import Foundation
import Testing
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

    @Test func theBrandPaletteIsTheBrandColours() {
        #expect(AppTheme.lagoon.palette.accent == .lagoonAqua)
        #expect(AppTheme.lagoon.palette.ground == .lagoonNavy)
        #expect(AppTheme.lagoon.palette.background == .black)
        #expect(AppTheme.lagoon.palette.surface == nil)
        #expect(AppTheme.babyPink.palette.surface != nil)
        #expect(AppTheme.lagoon.palette.controlTint == ThemePalette.paleAqua)
        #expect(AppTheme.babyPink.palette.controlTint == AppTheme.babyPink.palette.accent)
        #expect(AppTheme.lagoon.palette.glow == .fallback)
        #expect(AppTheme.lagoon.palette.artworkTint == nil)
        #expect(AppTheme.babyPink.palette.artworkTint != nil)
        #expect(AppTheme.lagoon.palette.chrome == nil)
        #expect(AppTheme.babyPink.palette.chrome != nil)
    }

    @Test func theBrandBloomsJellyfishAndPinkBloomsFlowers() {
        #expect(AppTheme.lagoon.bloomMotif == .jellyfish)
        #expect(AppTheme.babyPink.bloomMotif == .flowers)
    }

    @Test func artworkGlowsAreLeftAloneByTheBrandAndBlushedByPink() {
        let artwork = ArtworkPalette(colors: [.red, .green, .blue])
        #expect(AppTheme.lagoon.palette.glow(for: artwork) == artwork)
        let blushed = AppTheme.babyPink.palette.glow(for: artwork)
        #expect(blushed != artwork)
        #expect(blushed.colors.count == artwork.colors.count)
    }

    @Test func spookyIsAProfilesChoiceLikeAnyOther() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, now: { Self.september })
        store.configure(accountID: "server|me")
        store.select(.spooky)
        #expect(defaults.string(forKey: ThemeStore.key("server|me")) == "spooky")
        store.configure(accountID: "server|partner")
        #expect(store.theme == .lagoon)
        store.configure(accountID: "server|me")
        #expect(store.theme == .spooky)
        #expect(AppTheme.allCases == [.lagoon, .babyPink, .spooky])
    }

    @Test func onlySpookyHauntsAndItBloomsGhosts() {
        #expect(AppTheme.spooky.ornament == .haunted)
        #expect(AppTheme.lagoon.ornament == nil)
        #expect(AppTheme.babyPink.ornament == nil)
        #expect(AppTheme.spooky.bloomMotif == .ghosts)
        // Its forms, bars and glows follow it, as Baby Pink's do.
        let palette = AppTheme.spooky.palette
        #expect(palette.surface != nil)
        #expect(palette.chrome != nil)
        #expect(palette.glow(for: ArtworkPalette(colors: [.red, .green])) != ArtworkPalette(colors: [.red, .green]))
    }

    @Test func aGhostFitsItsRectAndItsFaceIsCutOut() {
        let rect = CGRect(x: 10, y: 20, width: 50, height: 60)
        for wave in stride(from: 0.0, through: 6.3, by: 0.7) {
            let bounds = GhostGeometry.path(in: rect, wave: wave).boundingRect
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "wave \(wave)")
        }
        let ghost = GhostGeometry.path(in: rect)
        // The body is filled; an eye is a hole in it.
        #expect(ghost.contains(CGPoint(x: rect.minX + 25, y: rect.minY + 12), eoFill: true))
        #expect(!ghost.contains(CGPoint(x: rect.minX + 16, y: rect.minY + 24), eoFill: true))
    }

    @Test func aCobwebStaysInItsCornerSquare() {
        let bounds = CobwebGeometry.path(size: 100).boundingRect
        #expect(bounds.minX >= -0.01 && bounds.minY >= -0.01)
        #expect(bounds.maxX <= 100.01 && bounds.maxY <= 100.01)
        // Its threads leave the corner, but none runs along an edge.
        #expect(bounds.width > 90 && bounds.height > 90)
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
}
