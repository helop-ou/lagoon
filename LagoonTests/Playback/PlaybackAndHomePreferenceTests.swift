import Foundation
import Testing
@testable import Lagoon

@Suite("Playback language preferences")
struct PlaybackLanguagePreferenceTests {
    private func candidate(
        _ language: String?,
        default isDefault: Bool = false,
        original: Bool = false,
        forced: Bool = false,
        hearingImpaired: Bool = false
    ) -> TrackSelectionCandidate {
        TrackSelectionCandidate(
            language: language,
            isDefault: isDefault,
            isOriginal: original,
            isForced: forced,
            isHearingImpaired: hearingImpaired
        )
    }

    @Test func originalMetadataOutranksTheDubbedServerDefault() {
        let streams = [
            candidate("eng", default: true),
            candidate("jpn", original: true),
        ]

        #expect(TrackSelectionPolicy.audioOrdinal(
            mode: .original,
            candidates: streams,
            serverDefault: 1,
            preferredLanguages: ["en"],
            originalLanguage: "eng"
        ) == 2)
    }

    @Test func itemOriginalLanguageIsUsedWhenOlderServersOmitIsOriginal() {
        let streams = [candidate("eng", default: true), candidate("ja-JP")]

        #expect(TrackSelectionPolicy.audioOrdinal(
            mode: .original,
            candidates: streams,
            serverDefault: 1,
            preferredLanguages: ["en"],
            originalLanguage: "jpn"
        ) == 2)
    }

    @Test func preferredAudioLanguagesAreOrderedAndNormalized() {
        let streams = [candidate("eng", default: true), candidate("est"), candidate("deu")]

        #expect(TrackSelectionPolicy.audioOrdinal(
            mode: .preferredLanguage,
            candidates: streams,
            serverDefault: 1,
            preferredLanguages: ["et-EE", "de-DE"],
            originalLanguage: nil
        ) == 2)
    }

    @Test func smartSubtitlesUseFullTextAcrossLanguagesAndForcedTextWithinOne() {
        let streams = [
            candidate("eng", default: true),
            candidate("eng", forced: true),
            candidate("est"),
        ]

        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .smart,
            candidates: streams,
            serverDefault: nil,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "jpn"
        ) == 1)
        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .smart,
            candidates: streams,
            serverDefault: nil,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "eng"
        ) == 2)
    }

    @Test func explicitSubtitleModesHandleOffForcedAndAlways() {
        let streams = [
            candidate("eng", forced: true),
            candidate("eng"),
        ]

        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .off,
            candidates: streams,
            serverDefault: 2,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "jpn"
        ) == 0)
        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .forcedOnly,
            candidates: streams,
            serverDefault: 2,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "jpn"
        ) == 1)
        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .always,
            candidates: streams,
            serverDefault: 1,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "eng"
        ) == 2)
    }

    @Test func jellyfinOriginalMetadataDecodesWithoutBreakingOlderResponses() throws {
        let item = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"movie","Type":"Movie","OriginalLanguage":"jpn"}"#.utf8)
        )
        let current = try JellyfinClient.decoder.decode(
            MediaStream.self,
            from: Data(#"{"Type":"Audio","Language":"jpn","IsOriginal":true}"#.utf8)
        )
        let older = try JellyfinClient.decoder.decode(
            MediaStream.self,
            from: Data(#"{"Type":"Audio","Language":"eng"}"#.utf8)
        )

        #expect(item.originalLanguage == "jpn")
        #expect(current.isOriginal == true)
        #expect(older.isOriginal == nil)
    }

    @Test @MainActor func choicesStayScopedToTheirServerAccount() {
        let suiteName = "PlaybackLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = TrackPreferencesStore(defaults: defaults)
        first.configure(accountID: "server-a:user")
        first.setPrimaryAudioLanguage("ja")
        var firstValues = first.values
        firstValues.audioMode = .original
        firstValues.subtitleMode = .smart
        first.values = firstValues

        let second = TrackPreferencesStore(defaults: defaults)
        second.configure(accountID: "server-b:user")
        #expect(second.values == TrackPreferenceValues())

        let restored = TrackPreferencesStore(defaults: defaults)
        restored.configure(accountID: "server-a:user")
        #expect(restored.values.audioMode == .original)
        #expect(restored.values.audioLanguageOverrides == ["ja"])
        #expect(restored.values.subtitleMode == .smart)
    }
}

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
    @Test func theSingleLegacyRecentlyAddedToggleHidesAllThreeRowsItBecame() throws {
        let values = try decoded(
            #"{"nativeRows":[{"id":"lagoon.recentlyAdded","isEnabled":false}]}"#
        )

        #expect(!values.isEnabled(HomeRowID.recentlyAddedMovies))
        #expect(!values.isEnabled(HomeRowID.recentlyAddedShows))
        #expect(!values.isEnabled(HomeRowID.recentlyAddedOther))
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

    @Test func nativeRowsIdentifyMovieAndShowGenresSeparately() {
        let choices = HomeSectionPreferenceResolver.nativeChoices

        #expect(choices.allSatisfy { $0.source == .lagoon })
        #expect(choices.map(\.id).contains(HomeRowID.movieGenres))
        #expect(choices.map(\.id).contains(HomeRowID.showGenres))
        #expect(choices.map(\.title).contains("Movie Genres"))
        #expect(choices.map(\.title).contains("Show Genres"))
    }

    /// Recently Added is three separately placeable rows.
    @Test func recentlyAddedIsOfferedOncePerKindOfLibrary() {
        let titles = Dictionary(
            HomeSectionPreferenceResolver.nativeChoices.map { ($0.id, $0.title) },
            uniquingKeysWith: { current, _ in current }
        )

        #expect(titles[HomeRowID.recentlyAddedMovies] == "Recently Added Movies")
        #expect(titles[HomeRowID.recentlyAddedShows] == "Recently Added Shows")
        #expect(titles[HomeRowID.recentlyAddedOther] == "Recently Added in Other Libraries")
        #expect(titles[HomeRowID.legacyRecentlyAdded] == nil)
    }

    /// Catches a new Home row that Settings never lists, which nobody could
    /// hide or move. Uses the identifier constants, not a copied list, so it
    /// fails as soon as the row has an id.
    @Test func everyRowWithAnIdentifierIsOfferedInSettings() {
        let offered = Set(HomeSectionPreferenceResolver.nativeChoices.map(\.id))
        let owned = [
            HomeRowID.continueWatching,
            HomeRowID.nextUp,
            HomeRowID.favorites,
            HomeRowID.recentlyAddedMovies,
            HomeRowID.recentlyAddedShows,
            HomeRowID.recentlyAddedOther,
            HomeRowID.movieGenres,
            HomeRowID.showGenres,
            HomeCuratedRows.ID.becauseYouWatched,
            HomeCuratedRows.ID.highlyRated,
            HomeCuratedRows.ID.topMovies,
            HomeCuratedRows.ID.inFourK,
            HomeCuratedRows.ID.genreSpotlight,
            HomeCuratedRows.ID.decadeSpotlight,
            HomeCuratedRows.ID.unstartedSeries,
            HomeCuratedRows.ID.topShows,
            HomeCuratedRows.ID.readyToBinge,
            HomeCuratedRows.ID.surpriseMe,
            CollectionShelf.rowID,
        ]

        for id in owned {
            #expect(offered.contains(id), "\(id) draws a row but Settings never lists it")
        }
        #expect(offered.count == owned.count)
    }

    /// The mirror: every id Settings offers must be drawn by Home.
    @Test func everyRowSettingsOffersIsOneHomeCanDraw() {
        let drawnByName: Set<String> = [
            HomeRowID.continueWatching,
            HomeRowID.nextUp,
            HomeRowID.favorites,
            HomeRowID.recentlyAddedMovies,
            HomeRowID.recentlyAddedShows,
            HomeRowID.recentlyAddedOther,
            HomeRowID.movieGenres,
            HomeRowID.showGenres,
            CollectionShelf.rowID,
        ]
        let drawnFromCuratedRails: Set<String> = [
            HomeCuratedRows.ID.becauseYouWatched,
            HomeCuratedRows.ID.highlyRated,
            HomeCuratedRows.ID.topMovies,
            HomeCuratedRows.ID.inFourK,
            HomeCuratedRows.ID.genreSpotlight,
            HomeCuratedRows.ID.decadeSpotlight,
            HomeCuratedRows.ID.unstartedSeries,
            HomeCuratedRows.ID.topShows,
            HomeCuratedRows.ID.readyToBinge,
            HomeCuratedRows.ID.surpriseMe,
        ]

        for choice in HomeSectionPreferenceResolver.nativeChoices {
            #expect(
                drawnByName.contains(choice.id) || drawnFromCuratedRails.contains(choice.id),
                "\(choice.id) is offered in Settings but Home draws nothing for it"
            )
        }
    }

    @Test func noTwoRowsShareAnIdentifier() {
        // A shared id means one control for two rows and a SwiftUI identity clash.
        let ids = HomeSectionPreferenceResolver.nativeChoices.map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    @Test func collectionsAreOfferedAndOnByDefault() {
        let choices = HomeSectionPreferenceResolver.nativeChoices
        let collections = choices.first { $0.id == CollectionShelf.rowID }

        #expect(collections?.title == "Collections")
        #expect(collections?.source == .lagoon)
        #expect(HomeSectionPreferenceValues().isEnabled(CollectionShelf.rowID))
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

@Suite("Home genre discovery")
struct HomeGenreDiscoveryTests {
    @Test func navigationRoutesKeepMovieAndShowGenresDistinct() {
        let movies = ContentNavigationRoute.genre(name: "Action", includeTypes: [.movie])
        let shows = ContentNavigationRoute.genre(name: "Action", includeTypes: [.series])

        #expect(movies != shows)
        #expect(Set([movies, shows]).count == 2)
    }

    @Test func contentRouteArrayPreservesNestedBackOrder() throws {
        let firstItem = try #require(candidates().first)
        let secondItem = try #require(candidates().dropFirst().first)
        var path: [ContentNavigationRoute] = [
            .genre(name: "Action", includeTypes: [.movie]),
            .item(firstItem),
            .item(secondItem),
        ]

        #expect(path.count == 3)
        #expect(path.removeLast() == .item(secondItem))
        #expect(path.removeLast() == .item(firstItem))
        #expect(path == [.genre(name: "Action", includeTypes: [.movie])])
    }

    private func candidates() throws -> [MediaItem] {
        let data = Data(#"""
        {"Items":[
            {"Id":"action-low","Name":"Action Low","Type":"Movie","CommunityRating":6.0,"Genres":["Action"],"BackdropImageTags":["low"]},
            {"Id":"drama-best-no-art","Name":"Drama Best","Type":"Series","CommunityRating":9.8,"Genres":["Drama"]},
            {"Id":"action-best","Name":"Action Best","Type":"Movie","CommunityRating":9.4,"Genres":["Action"],"BackdropImageTags":["best"]},
            {"Id":"drama-art","Name":"Drama Art","Type":"Series","CommunityRating":8.5,"Genres":["Drama"],"ImageTags":{"Thumb":"thumb"}},
            {"Id":"comedy","Name":"Comedy","Type":"Movie","CommunityRating":7.5,"Genres":["Comedy"],"BackdropImageTags":["comedy"]}
        ]}
        """#.utf8)
        return try JellyfinClient.decoder.decode(ItemsPage.self, from: data).items
    }

    @Test func highestRatedLandscapeTitleBecomesEachGenreBackground() throws {
        let genres = [
            MediaGenre(id: "action", name: "Action"),
            MediaGenre(id: "drama", name: "Drama"),
            MediaGenre(id: "comedy", name: "Comedy"),
            MediaGenre(id: "stale", name: "Stale Genre"),
        ]

        let shelf = GenreShelfResolver.resolve(catalog: genres, candidates: try candidates())

        #expect(shelf.map(\.name) == ["Action", "Drama", "Comedy"])
        #expect(shelf.first(where: { $0.name == "Action" })?.artwork?.id == "action-best")
        // The top Drama item has no landscape art, so the next one supplies it.
        #expect(shelf.first(where: { $0.name == "Drama" })?.artwork?.id == "drama-art")
    }

    @Test func candidatesProvideAUsefulFallbackWhenTheGenreEndpointIsUnavailable() throws {
        let shelf = GenreShelfResolver.resolve(
            catalog: [],
            candidates: try candidates(),
            limit: 2
        )

        #expect(shelf.map(\.name) == ["Action", "Drama"])
        #expect(shelf.allSatisfy { $0.id.hasPrefix("derived-") })
    }

    @Test func movieAndShowGenreShelvesDoNotMixMediaTypes() throws {
        let genres = [
            MediaGenre(id: "action", name: "Action"),
            MediaGenre(id: "drama", name: "Drama"),
            MediaGenre(id: "comedy", name: "Comedy"),
        ]

        let movies = GenreShelfResolver.resolve(
            catalog: genres,
            candidates: try candidates(),
            includeTypes: [.movie]
        )
        let shows = GenreShelfResolver.resolve(
            catalog: genres,
            candidates: try candidates(),
            includeTypes: [.series]
        )

        #expect(movies.map(\.name) == ["Action", "Comedy"])
        #expect(shows.map(\.name) == ["Drama"])
    }
}
