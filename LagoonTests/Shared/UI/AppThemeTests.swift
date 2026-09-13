import Foundation
import Testing
@testable import Lagoon

@Suite("App theme")
@MainActor
struct AppThemeTests {
    private func defaults() -> UserDefaults {
        let suite = "AppThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func themeFollowsTheProfile() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults)
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

    @Test func aChoiceCountsAsASelectionButLoadingOneDoesNot() {
        let store = ThemeStore(defaults: defaults())
        store.configure(accountID: "a")
        #expect(store.selectionCount == 0)
        store.select(.babyPink)
        #expect(store.selectionCount == 1)
        store.select(.babyPink)
        #expect(store.selectionCount == 1)
        store.configure(accountID: "b")
        store.configure(accountID: "a")
        #expect(store.theme == .babyPink)
        #expect(store.selectionCount == 1)
    }

    @Test func noAccountMeansTheBrandThemeAndNothingSaved() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults)
        store.configure(accountID: nil)
        store.select(.babyPink)
        #expect(store.theme == .babyPink)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(ThemeStore.keyPrefix) })
        store.configure(accountID: "a")
        #expect(store.theme == .lagoon)
    }

    @Test func aStrayStoreCannotUndoTheOwnersTheme() {
        let defaults = defaults()
        defaults.set("babyPink", forKey: ThemeStore.key("a"))
        let store = ThemeStore(defaults: defaults)
        let ownerObject = NSObject(), strayObject = NSObject()
        let owner = ObjectIdentifier(ownerObject), stray = ObjectIdentifier(strayObject)
        store.configure(accountID: "a", owner: owner)
        #expect(store.theme == .babyPink)
        store.configure(accountID: nil, owner: stray)
        #expect(store.theme == .babyPink)
        store.configure(accountID: nil, owner: owner)
        #expect(store.theme == .lagoon)
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
        #expect(AppTheme.lagoon.palette.controlTint == nil)
        #expect(AppTheme.babyPink.palette.controlTint != nil)
        #expect(AppTheme.lagoon.palette.glow == .fallback)
    }
}
