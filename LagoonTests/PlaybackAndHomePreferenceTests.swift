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

    @Test func untouchedLayoutPreservesTheExistingAdditiveDefault() throws {
        let selected = HomeSectionPreferenceResolver.sections(
            from: try catalog(),
            preferences: HomeSectionPreferenceValues(),
            nativelyCovered: ["ContinueWatching"]
        )

        #expect(selected.map(\.section) == ["MyList", "Recommendations"])
    }

    @Test func configuredLayoutWinsIncludingNativeSectionsAndOrder() throws {
        let preferences = HomeSectionPreferenceValues(
            isConfigured: true,
            rows: [
                HomeSectionPreferenceRow(id: "Recommendations", isEnabled: true),
                HomeSectionPreferenceRow(id: "ContinueWatching", isEnabled: true),
                HomeSectionPreferenceRow(id: "MyList", isEnabled: false),
            ]
        )
        let selected = HomeSectionPreferenceResolver.sections(
            from: try catalog(),
            preferences: preferences,
            nativelyCovered: ["ContinueWatching"]
        )

        #expect(selected.map(\.section) == ["Recommendations", "ContinueWatching"])
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

    @Test func nativeRowsIdentifyMovieAndShowGenresSeparately() {
        let choices = HomeSectionPreferenceResolver.nativeChoices

        #expect(choices.allSatisfy { $0.source == .lagoon })
        #expect(choices.map(\.id).contains("lagoon.movieGenres"))
        #expect(choices.map(\.id).contains("lagoon.showGenres"))
        #expect(choices.map(\.title).contains("Movie Genres"))
        #expect(choices.map(\.title).contains("Show Genres"))
    }

    /// The one that catches the next row someone adds.
    ///
    /// A Home row that never reaches this list is a row nobody can turn off,
    /// and the mistake is invisible: the row renders, Settings simply never
    /// mentions it. Asserting against the identifier constants rather than a
    /// hand-copied list means a new row fails here the moment it has an id
    /// and before it has a screen (HEL-122).
    @Test func everyRowWithAnIdentifierIsOfferedInSettings() {
        let offered = Set(HomeSectionPreferenceResolver.nativeChoices.map(\.id))
        let owned = [
            HomeCuratedRows.ID.becauseYouWatched,
            HomeCuratedRows.ID.highlyRated,
            HomeCuratedRows.ID.inFourK,
            HomeCuratedRows.ID.genreSpotlight,
            HomeCuratedRows.ID.decadeSpotlight,
            HomeCuratedRows.ID.unstartedSeries,
            HomeCuratedRows.ID.readyToBinge,
            HomeCuratedRows.ID.surpriseMe,
            CollectionShelf.rowID,
        ]

        for id in owned {
            #expect(offered.contains(id), "\(id) draws a row but Settings never lists it")
        }
    }

    @Test func noTwoRowsShareAnIdentifier() {
        // Two rows on one id is one toggle governing both, and the row list
        // is identified in SwiftUI — a duplicate is a runtime problem there
        // as well as a preferences one.
        let ids = HomeSectionPreferenceResolver.nativeChoices.map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    @Test func collectionsAreOfferedAndOnByDefault() {
        let choices = HomeSectionPreferenceResolver.nativeChoices
        let collections = choices.first { $0.id == CollectionShelf.rowID }

        #expect(collections?.title == "Collections")
        #expect(collections?.source == .lagoon)
        #expect(HomeSectionPreferenceValues().isNativeEnabled(CollectionShelf.rowID))
    }

    @Test func savedLayoutsFromBeforeNativeTogglesKeepEveryNativeRowVisible() throws {
        let legacy = Data(#"{"isConfigured":true,"rows":[]}"#.utf8)
        let values = try JSONDecoder().decode(HomeSectionPreferenceValues.self, from: legacy)

        #expect(values.nativeRows.isEmpty)
        #expect(values.isNativeEnabled("lagoon.continueWatching"))
        #expect(values.isNativeEnabled("lagoon.movieGenres"))
        #expect(values.isCustomized) // The legacy plugin layout remains custom.
    }

    @Test @MainActor func nativeVisibilityTogglePersistsAndRestoresTheDefault() {
        let suiteName = "HomeRowPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "server:user")
        store.toggleNative("lagoon.movieGenres")
        #expect(!store.values.isNativeEnabled("lagoon.movieGenres"))
        #expect(store.values.isCustomized)

        let restored = HomeSectionPreferencesStore(defaults: defaults)
        restored.configure(accountID: "server:user")
        #expect(!restored.values.isNativeEnabled("lagoon.movieGenres"))

        restored.toggleNative("lagoon.movieGenres")
        #expect(restored.values.isNativeEnabled("lagoon.movieGenres"))
        #expect(!restored.values.isCustomized)
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
        // The absolute top Drama item has no landscape art, so the next
        // highest-rated suitable title supplies the tile background.
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
