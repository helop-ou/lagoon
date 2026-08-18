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
}
