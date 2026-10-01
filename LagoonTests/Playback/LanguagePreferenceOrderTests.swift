import Testing
@testable import Lagoon

@Suite("Language preference order")
struct LanguagePreferenceOrderTests {
    @Test func overridesOutrankTheSystemAndEachLanguageAppearsOnce() {
        let order = LanguagePreferenceOrder(overrides: ["et"], system: ["en-US", "et-EE", "de"])
        #expect(order.preferred == ["et", "en", "de"])
    }

    @Test func primaryAndFallbackFallThroughToTheNormalizedSystemList() {
        let system = LanguagePreferenceOrder(overrides: [], system: ["en-US", "et-EE"])
        #expect(system.primary == "en")
        #expect(system.fallback == "et")

        let partial = LanguagePreferenceOrder(overrides: ["fr"], system: ["en-US", "et-EE"])
        #expect(partial.primary == "fr")
        #expect(partial.fallback == "et")
    }

    @Test func settingTheFallbackPinsTheSystemPrimaryFirst() {
        let order = LanguagePreferenceOrder(overrides: [], system: ["en-US", "et-EE"])
        #expect(order.settingFallback("de") == ["en", "de"])
        #expect(order.settingFallback(nil) == ["en"])
    }

    @Test func settingThePrimaryKeepsTheFallbackAndDropsDuplicates() {
        let order = LanguagePreferenceOrder(overrides: ["en", "et"], system: [])
        #expect(order.settingPrimary("de") == ["de", "et"])
        #expect(order.settingPrimary("et") == ["et"])
        #expect(order.settingPrimary(nil) == ["et"])
    }
}
