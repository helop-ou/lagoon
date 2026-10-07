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
        hearingImpaired: Bool = false,
        title: String? = nil
    ) -> TrackSelectionCandidate {
        TrackSelectionCandidate(
            language: language,
            isDefault: isDefault,
            isOriginal: original,
            isForced: forced,
            isHearingImpaired: hearingImpaired,
            isTitledForced: TrackSelectionPolicy.titleNamesForcedTrack(title)
        )
    }

    private func subtitle(
        _ mode: SubtitleDefaultMode,
        _ streams: [TrackSelectionCandidate],
        audio: String,
        serverDefault: Int? = nil
    ) -> Int? {
        TrackSelectionPolicy.subtitleOrdinal(
            mode: mode,
            candidates: streams,
            serverDefault: serverDefault,
            preferredLanguages: ["en"],
            selectedAudioLanguage: audio,
            captionDisplay: .automatic
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
            selectedAudioLanguage: "jpn",
            captionDisplay: .automatic
        ) == 1)
        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .smart,
            candidates: streams,
            serverDefault: nil,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "eng",
            captionDisplay: .automatic
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
            selectedAudioLanguage: "jpn",
            captionDisplay: .automatic
        ) == 0)
        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .forcedOnly,
            candidates: streams,
            serverDefault: 2,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "jpn",
            captionDisplay: .automatic
        ) == 1)
        #expect(TrackSelectionPolicy.subtitleOrdinal(
            mode: .always,
            candidates: streams,
            serverDefault: 1,
            preferredLanguages: ["en"],
            selectedAudioLanguage: "eng",
            captionDisplay: .automatic
        ) == 2)
    }

    @Test func signsAndSongsTitlesAreRecognisedAsWholeWords() {
        for title in ["Signs & Songs", "signs/songs", "English [S&S]", "Songs", "English (Forced)", "SIGNS"] {
            #expect(TrackSelectionPolicy.titleNamesForcedTrack(title), "\(title)")
        }
        for title in [
            nil, "", "English", "English SDH", "Full Dialogue", "Designs", "Unforced", "Brass & Strings",
            // Full tracks that name what they carry.
            "English (Songs & Signs included)", "English (Non-Forced)", "Not Forced", "Full + Signs",
            "Dialogue + Songs", "Signs & Songs (SDH)", "English (Full, incl. Signs)",
        ] {
            #expect(!TrackSelectionPolicy.titleNamesForcedTrack(title), "\(title ?? "nil")")
        }
    }

    @Test func smartPicksAnUnflaggedSignsTrackForEnglishAudioAndDialogueForJapanese() {
        // The signs track is Jellyfin's default, which once made it the
        // full-dialogue choice too.
        let streams = [
            candidate("eng", default: true, title: "Signs & Songs"),
            candidate("eng", title: "Dialogue"),
        ]

        #expect(subtitle(.smart, streams, audio: "eng") == 1)
        #expect(subtitle(.forcedOnly, streams, audio: "eng") == 1)
        #expect(subtitle(.smart, streams, audio: "jpn") == 2)
        #expect(subtitle(.always, streams, audio: "jpn") == 2)
    }

    @Test func aRealForcedFlagOutranksATitledSignsTrack() {
        let streams = [
            candidate("eng", title: "Signs & Songs"),
            candidate("eng", forced: true, title: "English"),
            candidate("eng", title: "Full"),
        ]

        #expect(subtitle(.smart, streams, audio: "eng") == 2)
        #expect(subtitle(.forcedOnly, streams, audio: "eng") == 2)
        #expect(subtitle(.smart, streams, audio: "jpn") == 3)
    }

    @Test func aFlaggedForcedTrackInAnotherLanguageOutranksATitledOneAsFallback() {
        let streams = [
            candidate("jpn", title: "Signs"),
            candidate("jpn", title: "Full"),
            candidate("est", forced: true),
        ]

        #expect(subtitle(.forcedOnly, streams, audio: "eng") == 3)
    }

    @Test func ordinaryReleasesSelectWhatTheyDidBeforeTitlesCounted() {
        let layouts: [[(language: String, forced: Bool, hearingImpaired: Bool, title: String?)]] = [
            // A film called Signs, its release name on every track.
            [("eng", false, false, "Signs.2002.1080p.BluRay"), ("eng", false, true, "Signs.2002.1080p.BluRay")],
            // A lone track is never taken for a signs track.
            [("eng", false, false, "English (Songs)"), ("est", false, false, nil)],
            // A flagged forced track beside a full one.
            [("eng", true, false, "Forced"), ("eng", false, false, "English"), ("est", false, true, nil)],
            // A full track that names the signs it carries, beside SDH.
            [("eng", false, false, "English (Songs & Signs included)"), ("eng", false, true, "English SDH")],
            [("eng", false, false, "English (Non-Forced)"), ("eng", false, true, "English SDH")],
            // Untitled tracks, as most movies and shows carry them.
            [("eng", false, false, nil), ("eng", false, true, "SDH"), ("est", false, false, nil)],
        ]
        for layout in layouts {
            let titled = layout.map {
                candidate($0.language, forced: $0.forced, hearingImpaired: $0.hearingImpaired, title: $0.title)
            }
            let untitled = layout.map {
                candidate($0.language, forced: $0.forced, hearingImpaired: $0.hearingImpaired)
            }
            for mode in SubtitleDefaultMode.allCases {
                for audio in ["eng", "jpn"] {
                    for serverDefault in [nil, 1] {
                        #expect(
                            subtitle(mode, titled, audio: audio, serverDefault: serverDefault)
                                == subtitle(mode, untitled, audio: audio, serverDefault: serverDefault),
                            "\(mode) \(audio) \(layout.map(\.title))"
                        )
                    }
                }
            }
        }
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
