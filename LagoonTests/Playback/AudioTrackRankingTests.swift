import Testing
@testable import Lagoon

@Suite("Audio track ranking")
struct AudioTrackRankingTests {
    private func audio(
        _ language: String?,
        _ title: String? = nil,
        default isDefault: Bool = false,
        original: Bool = false
    ) -> TrackSelectionCandidate {
        TrackSelectionCandidate(
            language: language,
            isDefault: isDefault,
            isOriginal: original,
            isForced: false,
            isHearingImpaired: false,
            isCommentary: TrackSelectionPolicy.titleNamesCommentary(title),
            isAudioDescription: TrackSelectionPolicy.titleNamesAudioDescription(title)
        )
    }

    private func ordinal(
        _ mode: AudioDefaultMode,
        _ candidates: [TrackSelectionCandidate],
        serverDefault: Int? = nil,
        originalLanguage: String? = nil,
        descriptions: Bool = false
    ) -> Int? {
        TrackSelectionPolicy.audioOrdinal(
            mode: mode,
            candidates: candidates,
            serverDefault: serverDefault,
            preferredLanguages: ["en"],
            originalLanguage: originalLanguage,
            prefersAudioDescriptions: descriptions
        )
    }

    // MARK: - Titles

    @Test func commentaryTitlesAreRecognised() {
        for title in ["Commentary", "Director's Commentary", "English - Commentary with cast", "COMMENTARIES"] {
            #expect(TrackSelectionPolicy.titleNamesCommentary(title), "\(title)")
        }
        for title in [nil, "Main", "Commentator", "Stereo"] as [String?] {
            #expect(!TrackSelectionPolicy.titleNamesCommentary(title), "\(title ?? "nil")")
        }
    }

    @Test func audioDescriptionTitlesAreRecognised() {
        for title in [
            "Audio Description", "English (Descriptive Audio)", "Described Video",
            "Visually Impaired", "DVS", "English AD", "AD - Stereo", "Audio-described",
        ] {
            #expect(TrackSelectionPolicy.titleNamesAudioDescription(title), "\(title)")
        }
        for title in [nil, "Main", "Ad", "Headphones", "Advanced 5.1", "Description of tracks"] as [String?] {
            #expect(!TrackSelectionPolicy.titleNamesAudioDescription(title), "\(title ?? "nil")")
        }
    }

    // MARK: - Commentary

    @Test func commentaryInThePreferredLanguageLosesToTheMainTrack() {
        let tracks = [audio("jpn", default: true), audio("eng", "Commentary"), audio("eng", "Main")]
        #expect(ordinal(.preferredLanguage, tracks, serverDefault: 1) == 3)
    }

    @Test func defaultFlaggedCommentaryStillLosesToTheMainTrack() {
        let tracks = [audio("eng", "Commentary", default: true), audio("eng")]
        #expect(ordinal(.preferredLanguage, tracks, serverDefault: 1) == 2)
    }

    @Test func jellyfinDefaultOnACommentaryMovesToTheMainTrackInItsLanguage() {
        let tracks = [audio("jpn"), audio("eng", "Commentary"), audio("eng")]
        #expect(ordinal(.serverDefault, tracks, serverDefault: 2) == 3)
    }

    @Test func jellyfinDefaultOnAMainTrackStands() {
        let tracks = [audio("jpn"), audio("eng", "Commentary"), audio("eng")]
        #expect(ordinal(.serverDefault, tracks, serverDefault: 1) == 1)
    }

    @Test func aLoneCommentaryInTheLanguageIsStillPicked() {
        let tracks = [audio("jpn", default: true), audio("eng", "Commentary")]
        #expect(ordinal(.preferredLanguage, tracks, serverDefault: 1) == 2)
    }

    @Test func originalModeSkipsAnOriginalLanguageCommentary() {
        let tracks = [audio("eng", default: true), audio("jpn", "Commentary"), audio("jpn")]
        #expect(ordinal(.original, tracks, serverDefault: 1, originalLanguage: "jpn") == 3)
    }

    // MARK: - Audio description

    @Test func describedTrackLosesToTheMainTrackWithTheSettingOff() {
        let tracks = [audio("eng", "Audio Description", default: true), audio("eng"), audio("eng", "Commentary")]
        #expect(ordinal(.preferredLanguage, tracks, serverDefault: 1) == 2)
        #expect(ordinal(.serverDefault, tracks, serverDefault: 1) == 2)
    }

    @Test func describedTrackWinsWithTheSettingOn() {
        let tracks = [audio("eng", default: true), audio("eng", "Commentary"), audio("eng", "Audio Description")]
        #expect(ordinal(.preferredLanguage, tracks, serverDefault: 1, descriptions: true) == 3)
        #expect(ordinal(.serverDefault, tracks, serverDefault: 1, descriptions: true) == 3)
    }

    @Test func theSettingNeverCrossesLanguages() {
        let tracks = [audio("eng", default: true), audio("fra", "Audio Description")]
        #expect(ordinal(.serverDefault, tracks, serverDefault: 1, descriptions: true) == 1)
        #expect(ordinal(.preferredLanguage, tracks, serverDefault: 1, descriptions: true) == 1)
    }
}
