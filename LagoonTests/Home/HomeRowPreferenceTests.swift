import Foundation
import Testing
@testable import Lagoon

@Suite("Home row preferences")
struct HomeRowPreferenceTests {
    private func catalog() throws -> [JellyfinClient.HomeSection] {
        let data = Data(#"{"Items":[{"Section":"ContinueWatching","DisplayText":"Continue Watching","OrderIndex":999},{"Section":"MyList","DisplayText":"My List","OrderIndex":999},{"Section":"Recommendations","DisplayText":"Recommendations","OrderIndex":999}]}"#.utf8)
        struct Page: Decodable { let items: [JellyfinClient.HomeSection] }
        return try JellyfinClient.decoder.decode(Page.self, from: data).items
    }

    private func duplicateCatalog() throws -> [JellyfinClient.HomeSection] {
        let data = Data(#"{"Items":[{"Section":"MyList","DisplayText":"My List","OrderIndex":1},{"Section":"MyList","DisplayText":"Duplicate My List","OrderIndex":2},{"Section":"Recommendations","DisplayText":"Recommendations","OrderIndex":3}]}"#.utf8)
        struct Page: Decodable { let items: [JellyfinClient.HomeSection] }
        return try JellyfinClient.decoder.decode(Page.self, from: data).items
    }

    private func decoded(_ json: String) throws -> HomeSectionPreferenceValues {
        try JSONDecoder().decode(HomeSectionPreferenceValues.self, from: Data(json.utf8))
    }

    private func order(
        _ values: HomeSectionPreferenceValues,
        plugins: [String] = []
    ) -> [String] {
        HomeSectionPreferenceResolver.renderOrder(preferences: values, pluginSections: plugins)
    }

    // MARK: The default order

    /// The six rows, in their default order.
    @Test func theDefaultOrderOpensWithWatchingThenWhatEachLibraryGained() {
        let opening = Array(order(HomeSectionPreferenceValues()).prefix(6))

        #expect(opening == [
            HomeRowID.continueWatching,
            HomeRowID.nextUp,
            HomeRowID.recentlyAddedMovies,
            HomeCuratedRows.ID.topMovies,
            HomeRowID.recentlyAddedShows,
            HomeCuratedRows.ID.topShows,
        ])
    }

    @Test func anAccountThatHasArrangedNothingShowsEveryNativeRow() {
        #expect(Set(order(HomeSectionPreferenceValues())) == HomeSectionPreferenceResolver.nativeIDs)
        #expect(!HomeSectionPreferenceValues().isCustomized)
    }

    @Test func pluginRowsFollowTheNativeBlockUntilOneIsMoved() {
        let ids = order(HomeSectionPreferenceValues(), plugins: ["MyList", "Recommendations"])

        #expect(Array(ids.suffix(2)) == ["MyList", "Recommendations"])
    }

    /// The point of the unified list: a plugin row can sit anywhere.
    @Test func anArrangementCanPutAPluginRowBetweenTwoNativeRows() {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.insert(HomeSectionPreferenceRow(id: "MyList", isEnabled: true), at: 1)

        let ids = order(HomeSectionPreferenceValues(layout: layout), plugins: ["MyList"])

        #expect(ids[0] == HomeRowID.continueWatching)
        #expect(ids[1] == "MyList")
        #expect(ids[2] == HomeRowID.nextUp)
    }

    @Test func aHiddenRowIsLeftOutOfTheOrderButKeptInTheArrangement() {
        let layout = HomeSectionPreferenceResolver.defaultLayout.map {
            HomeSectionPreferenceRow(id: $0.id, isEnabled: $0.id != HomeRowID.favorites)
        }
        let values = HomeSectionPreferenceValues(layout: layout)

        #expect(!order(values).contains(HomeRowID.favorites))
        #expect(values.layout.contains { $0.id == HomeRowID.favorites })
        #expect(values.isCustomized)
    }

    // MARK: Reconciling an arrangement with the rows that exist now

    /// A row added in a later build lands at its designed place, not at the
    /// bottom under the plugin rows.
    @Test func aNewNativeRowIsInsertedWhereItWasDesignedToGo() {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.removeAll { $0.id == HomeCuratedRows.ID.topMovies }

        let reconciled = HomeSectionPreferenceResolver.reconciled(layout, sections: [])

        #expect(reconciled.map(\.id) == HomeSectionPreferenceResolver.defaultLayout.map(\.id))
        #expect(reconciled.first { $0.id == HomeCuratedRows.ID.topMovies }?.isEnabled == true)
    }

    @Test func aFirstNativeRowWithNoPredecessorStillLandsAtTheTop() {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.removeAll { $0.id == HomeRowID.continueWatching }

        let reconciled = HomeSectionPreferenceResolver.reconciled(layout, sections: [])

        #expect(reconciled.first?.id == HomeRowID.continueWatching)
    }

    @Test func aSectionGainedAfterPluginRowsWereArrangedArrivesHidden() {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.insert(HomeSectionPreferenceRow(id: "MyList", isEnabled: true), at: 0)

        let reconciled = HomeSectionPreferenceResolver.reconciled(
            layout,
            sections: ["MyList", "Recommendations"]
        )

        #expect(reconciled.first { $0.id == "Recommendations" }?.isEnabled == false)
        #expect(reconciled.first { $0.id == "MyList" }?.isEnabled == true)
    }

    /// Hiding a native row says nothing about plugin rows, so they arrive shown.
    @Test func theCatalogueArrivesShownWhenNoPluginRowWasEverArranged() {
        let reconciled = HomeSectionPreferenceResolver.reconciled(
            HomeSectionPreferenceResolver.defaultLayout,
            sections: ["MyList"]
        )

        #expect(reconciled.first { $0.id == "MyList" }?.isEnabled == true)
    }

    /// A failed `homeSections()` returns an empty catalogue, so reconciling
    /// must not prune unknown rows.
    @Test func anEmptyCatalogueNeverDropsARememberedPluginRow() {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.append(HomeSectionPreferenceRow(id: "MyList", isEnabled: true))

        let reconciled = HomeSectionPreferenceResolver.reconciled(layout, sections: [])

        #expect(reconciled.map(\.id).contains("MyList"))
    }

    /// A retired native row would sit in Settings with nothing to draw.
    @Test func aNativeRowLagoonNoLongerOffersIsDropped() {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.insert(HomeSectionPreferenceRow(id: "lagoon.recentlyAddedOther", isEnabled: true), at: 3)
        layout.append(HomeSectionPreferenceRow(id: "MyList", isEnabled: true))

        let reconciled = HomeSectionPreferenceResolver.reconciled(layout, sections: [])

        #expect(!reconciled.map(\.id).contains("lagoon.recentlyAddedOther"))
        #expect(reconciled.map(\.id).contains("MyList"))
    }

    @Test func reconcilingLeavesAnUnarrangedAccountAlone() {
        let reconciled = HomeSectionPreferenceResolver.reconciled([], sections: ["MyList"])

        #expect(reconciled.isEmpty)
    }

    // MARK: Which plugin sections are fetched

    @Test func untouchedLayoutPreservesTheExistingAdditiveDefault() throws {
        let selected = HomeSectionPreferenceResolver.sections(
            from: try catalog(),
            preferences: HomeSectionPreferenceValues(),
            nativelyCovered: ["ContinueWatching"]
        )

        #expect(selected.map(\.section) == ["MyList", "Recommendations"])
    }

    @Test func anArrangementDecidesWhichPluginSectionsAppearAndInWhatOrder() throws {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.insert(HomeSectionPreferenceRow(id: "Recommendations", isEnabled: true), at: 0)
        layout.append(HomeSectionPreferenceRow(id: "MyList", isEnabled: false))

        let selected = HomeSectionPreferenceResolver.sections(
            from: try catalog(),
            preferences: HomeSectionPreferenceValues(layout: layout),
            nativelyCovered: ["ContinueWatching"]
        )

        #expect(selected.map(\.section) == ["Recommendations"])
    }

    /// A section Lagoon draws itself stays out even when an arrangement names
    /// it, so it cannot duplicate a native row.
    @Test func aNativelyCoveredSectionStaysOutEvenWhenTheArrangementNamesIt() throws {
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.insert(HomeSectionPreferenceRow(id: "ContinueWatching", isEnabled: true), at: 0)

        let selected = HomeSectionPreferenceResolver.sections(
            from: try catalog(),
            preferences: HomeSectionPreferenceValues(layout: layout),
            nativelyCovered: ["ContinueWatching"]
        )

        #expect(!selected.map(\.section).contains("ContinueWatching"))
    }

    @Test func duplicateServerSectionsAreCollapsedWithoutChangingTheirOrder() throws {
        let selected = HomeSectionPreferenceResolver.sections(
            from: try duplicateCatalog(),
            preferences: HomeSectionPreferenceValues(),
            nativelyCovered: []
        )

        #expect(selected.map(\.section) == ["MyList", "Recommendations"])
        #expect(selected.first?.displayText == "My List")
    }

    // MARK: Layouts saved beforehand

    @Test func anUntouchedLegacyLayoutAdoptsTheNewDefaultOrder() throws {
        let values = try decoded(#"{"isConfigured":false,"rows":[],"nativeRows":[]}"#)

        #expect(values.layout.isEmpty)
        #expect(!values.isCustomized)
        #expect(order(values).first == HomeRowID.continueWatching)
    }

    /// Hiding a row is not a choice about order, so the default order applies.
    @Test func aLegacyHiddenRowSurvivesIntoTheNewDefaultOrder() throws {
        let values = try decoded(
            #"{"isConfigured":false,"rows":[],"nativeRows":[{"id":"lagoon.movieGenres","isEnabled":false}]}"#
        )

        #expect(!values.isEnabled(HomeRowID.movieGenres))
        #expect(values.isEnabled(HomeRowID.continueWatching))
        #expect(values.layout.map(\.id) == HomeSectionPreferenceResolver.defaultLayout.map(\.id))
    }

    /// The old single Recently Added toggle carries to all three rows.
    @Test func theSingleLegacyRecentlyAddedToggleHidesEveryRowItBecame() throws {
        let values = try decoded(
            #"{"nativeRows":[{"id":"lagoon.recentlyAdded","isEnabled":false}]}"#
        )

        #expect(!values.isEnabled(HomeRowID.recentlyAddedMovies))
        #expect(!values.isEnabled(HomeRowID.recentlyAddedShows))
    }

    @Test func aLegacyPluginOrderIsKeptAfterTheNativeBlock() throws {
        let values = try decoded(
            #"{"isConfigured":true,"rows":[{"id":"Recommendations","isEnabled":true},{"id":"MyList","isEnabled":false}]}"#
        )
        let nativeCount = HomeSectionPreferenceResolver.defaultLayout.count

        #expect(values.layout.map(\.id).suffix(2) == ["Recommendations", "MyList"])
        #expect(values.layout.count == nativeCount + 2)
        #expect(!values.isEnabled("MyList"))
    }

    @Test func savedLayoutsFromBeforeNativeTogglesKeepEveryNativeRowVisible() throws {
        let values = try decoded(#"{"isConfigured":true,"rows":[]}"#)

        #expect(values.isEnabled(HomeRowID.continueWatching))
        #expect(values.isEnabled(HomeRowID.movieGenres))
        #expect(values.isCustomized)
    }

    @Test func theNewShapeWinsOverAnythingLeftFromTheOldOne() throws {
        let values = try decoded(
            #"{"layout":[{"id":"lagoon.nextUp","isEnabled":false}],"isConfigured":true,"rows":[{"id":"MyList","isEnabled":true}]}"#
        )

        #expect(values.layout.map(\.id) == [HomeRowID.nextUp])
    }

    @Test func anArrangementRoundTripsThroughItsOwnStoredShape() throws {
        let values = HomeSectionPreferenceValues(
            layout: [HomeSectionPreferenceRow(id: HomeRowID.nextUp, isEnabled: false)]
        )

        let encoded = try JSONEncoder().encode(values)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"layout\""))
        #expect(try JSONDecoder().decode(HomeSectionPreferenceValues.self, from: encoded) == values)
    }

    // MARK: The rows Settings offers

    /// The old single Recently Added row became one per kind of library and
    /// must not linger in Settings as a row nothing draws.
    @Test func theLegacyRecentlyAddedRowIsNotOffered() {
        let offered = HomeSectionPreferenceResolver.nativeChoices.map(\.id)

        #expect(!offered.contains(HomeRowID.legacyRecentlyAdded))
    }

    /// Catches a new Home row that Settings never lists, which nobody could
    /// hide or move. Uses the table `HomeView` draws from, not a copied list.
    @Test func everyRowHomeDrawsIsOfferedInSettings() {
        let drawn = Set(HomeRowKind.native.keys)

        for id in drawn {
            #expect(HomeSectionPreferenceResolver.nativeIDs.contains(id), "\(id) draws a row but Settings never lists it")
        }
        #expect(drawn == HomeSectionPreferenceResolver.nativeIDs)
    }

    /// The mirror: an offered id without a kind falls through to nothing.
    @Test func everyRowSettingsOffersIsOneHomeCanDraw() {
        for choice in HomeSectionPreferenceResolver.nativeChoices {
            #expect(HomeRowKind(id: choice.id) != nil, "\(choice.id) is offered in Settings but Home draws nothing for it")
        }
    }

    /// Rows with a view of their own must not fall back to a curated rail,
    /// which reads `curatedRails` and finds nothing under their id.
    @Test func rowsWithTheirOwnViewAreNotDrawnAsCuratedRails() {
        #expect(HomeRowKind(id: CollectionShelf.rowID) == .collections)
        #expect(HomeRowKind(id: HomeCuratedRows.ID.topMovies) == .topTen)
        #expect(HomeRowKind(id: HomeCuratedRows.ID.topShows) == .topTen)
    }

    @Test func aRetiredNativeRowDrawsNothingAndAPluginSectionDrawsItsRail() {
        #expect(HomeRowKind(id: "lagoon.recentlyAddedOther") == nil)
        #expect(HomeRowKind(id: "MyList") == .plugin(section: "MyList"))
    }

    @Test func noTwoRowsShareAnIdentifier() {
        // A shared id means one control for two rows and a SwiftUI identity clash.
        let ids = HomeSectionPreferenceResolver.nativeChoices.map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    // MARK: The store

    @Test @MainActor func hidingARowPersistsAndResetRestoresTheDefault() {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        #expect(!store.values.isCustomized)

        store.toggle(HomeRowID.movieGenres)
        #expect(!store.values.isEnabled(HomeRowID.movieGenres))
        #expect(store.values.isCustomized)

        let restored = HomeSectionPreferencesStore(defaults: defaults)
        restored.configure(accountID: "server:user")
        #expect(!restored.values.isEnabled(HomeRowID.movieGenres))

        restored.reset()
        #expect(restored.values.isEnabled(HomeRowID.movieGenres))
        #expect(!restored.values.isCustomized)
    }

    @Test @MainActor func movingARowPersistsItsNewPlace() {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        let moved = HomeRowID.continueWatching
        #expect(store.choices.first?.id == moved)

        store.move(moved, by: 1)
        #expect(store.choices[1].id == moved)

        let restored = HomeSectionPreferencesStore(defaults: defaults)
        restored.configure(accountID: "server:user")
        #expect(restored.choices[1].id == moved)

        restored.move(moved, by: -1)
        #expect(restored.choices.first?.id == moved)
    }

    @Test @MainActor func aRowCannotBeMovedPastEitherEndOfTheList() {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        let before = store.choices.map(\.id)

        store.move(before.first!, by: -1)
        store.move(before.last!, by: 1)

        #expect(store.choices.map(\.id) == before)
    }

    /// Settings lists hidden rows too; it is the only way to bring one back.
    @Test @MainActor func settingsKeepsListingARowAfterItIsHidden() {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        store.toggle(HomeRowID.favorites)

        let hidden = store.choices.first { $0.id == HomeRowID.favorites }
        #expect(hidden?.isEnabled == false)
        #expect(store.choices.count == HomeSectionPreferenceResolver.nativeChoices.count)
    }

    /// The server's sections join a saved arrangement as soon as Settings
    /// loads them, and the result is saved; rows Lagoon draws natively are
    /// never offered twice.
    @Test @MainActor func aLoadedCatalogueJoinsTheArrangementAndIsSaved() async throws {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.append(HomeSectionPreferenceRow(id: "MyList", isEnabled: true))
        defaults.set(
            try JSONEncoder().encode(HomeSectionPreferenceValues(layout: layout)),
            forKey: HomeSectionPreferencesStore.key("server:user")
        )
        StubURLProtocol.register(host: "home-sections.test") { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"Items":[{"Section":"ContinueWatching","DisplayText":"Continue Watching"},{"Section":"MyList","DisplayText":"My List"},{"Section":"Recommendations","DisplayText":"Recommendations"}]}"#.utf8))
        }
        defer { StubURLProtocol.unregister(host: "home-sections.test") }
        let client = StubURLProtocol.makeJellyfinClient(host: "home-sections.test", deviceId: "home-sections-tests")

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        await store.loadCatalog(client: client)

        let plugins = store.choices.filter { $0.source == .plugin }
        #expect(plugins.map(\.id) == ["MyList", "Recommendations"])
        #expect(plugins.map(\.isEnabled) == [true, false])
        let restored = HomeSectionPreferencesStore.savedValues(accountID: "server:user", defaults: defaults)
        #expect(restored.layout.suffix(2).map(\.id) == ["MyList", "Recommendations"])
    }

    /// A remembered plugin row the server stopped offering is not listed, so
    /// a drag must not move it or lose it.
    @Test @MainActor func draggingRowsLeavesAnUnofferedPluginRowWhereItWas() throws {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var layout = HomeSectionPreferenceResolver.defaultLayout
        layout.insert(HomeSectionPreferenceRow(id: "Retired", isEnabled: true), at: 1)
        defaults.set(
            try JSONEncoder().encode(HomeSectionPreferenceValues(layout: layout)),
            forKey: HomeSectionPreferencesStore.key("server:user")
        )
        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        #expect(!store.choices.map(\.id).contains("Retired"))

        // Continue Watching below Next Up.
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(Array(store.values.layout.prefix(3).map(\.id)) == [
            HomeRowID.nextUp, "Retired", HomeRowID.continueWatching,
        ])
        #expect(store.values.layout.count == layout.count)
    }

    @Test @MainActor func arrangementsDoNotLeakBetweenAccounts() {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:first")
        store.toggle(HomeRowID.favorites)

        store.configure(accountID: "server:second")
        #expect(store.values.isEnabled(HomeRowID.favorites))
        #expect(!store.values.isCustomized)
    }
}
