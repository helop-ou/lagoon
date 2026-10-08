import Foundation
import Testing
@testable import Lagoon

@Suite("Playback track plan")
struct PlaybackTrackPlanTests {
    private func stream(
        _ type: String,
        index: Int,
        language: String? = nil,
        title: String? = nil,
        displayTitle: String? = nil,
        isDefault: Bool = false,
        forced: Bool = false,
        hearingImpaired: Bool = false,
        external: Bool = false
    ) throws -> MediaStream {
        var json: [String: Any] = [
            "Type": type,
            "Index": index,
            "IsDefault": isDefault,
            "IsForced": forced,
            "IsHearingImpaired": hearingImpaired,
            "IsExternal": external,
        ]
        json["Language"] = language
        json["Title"] = title
        json["DisplayTitle"] = displayTitle
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JellyfinClient.decoder.decode(MediaStream.self, from: data)
    }

    private func plan(
        audio: [MediaStream] = [],
        subtitles: [MediaStream] = [],
        external: [MediaStream] = [],
        defaultAudio: Int? = nil,
        defaultSubtitle: Int? = nil,
        settings: TrackSelectionSettings = TrackSelectionSettings(
            preferredAudioLanguages: ["en"],
            preferredSubtitleLanguages: ["en"]
        ),
        captionDisplay: SystemCaptionDisplay = .automatic,
        carry: PlaybackTrackPlan.Carry? = nil,
        rememberedAudio: RememberedAudioChoice? = nil,
        rememberedSubtitle: RememberedSubtitleChoice? = nil,
        bench: String? = nil
    ) -> PlaybackTrackPlan {
        PlaybackTrackPlan(
            audio: audio,
            embeddedSubtitles: subtitles,
            externalSubtitles: external,
            serverDefaultAudioIndex: defaultAudio,
            serverDefaultSubtitleIndex: defaultSubtitle,
            settings: settings,
            originalLanguage: nil,
            captionDisplay: captionDisplay,
            memoryScope: "series",
            carry: carry,
            rememberedAudio: rememberedAudio,
            rememberedSubtitle: rememberedSubtitle,
            benchSubtitleLanguage: bench
        )
    }

    /// Three audio tracks at stream indexes 1-3: English, Japanese, a
    /// commentary.
    private func threeAudio() throws -> [MediaStream] {
        [
            try stream("Audio", index: 1, language: "eng", title: "Main"),
            try stream("Audio", index: 2, language: "jpn", title: "Main"),
            try stream("Audio", index: 3, language: "eng", title: "Commentary"),
        ]
    }

    // MARK: - Precedence

    @Test func serverDefaultIsTheAutomaticAudioChoice() throws {
        let plan = plan(audio: try threeAudio(), defaultAudio: 2)
        #expect(plan.automaticAudioOrdinal == 2)
        #expect(plan.initialAudioOrdinal == 2)
    }

    @Test func carryOutranksAutomaticAudio() throws {
        let plan = plan(
            audio: try threeAudio(),
            defaultAudio: 1,
            carry: .init(audioLanguage: "eng", audioTitle: "Commentary", subtitlesOff: false)
        )
        #expect(plan.automaticAudioOrdinal == 1)
        #expect(plan.initialAudioOrdinal == 3)
    }

    @Test func rememberedChoiceOutranksCarry() throws {
        let plan = plan(
            audio: try threeAudio(),
            defaultAudio: 1,
            carry: .init(audioLanguage: "eng", audioTitle: "Commentary", subtitlesOff: false),
            rememberedAudio: RememberedAudioChoice(language: "jpn", title: "Main", ordinal: 2, layout: "")
        )
        #expect(plan.initialAudioOrdinal == 2)
    }

    @Test func rememberedChoiceThatMatchesNothingLeavesCarry() throws {
        let plan = plan(
            audio: try threeAudio(),
            defaultAudio: 1,
            carry: .init(audioLanguage: "eng", audioTitle: "Commentary", subtitlesOff: false),
            rememberedAudio: RememberedAudioChoice(language: "fra", title: nil, ordinal: 9, layout: "")
        )
        #expect(plan.initialAudioOrdinal == 3)
    }

    @Test func carriedSubtitlesOffOutranksTheServerDefault() throws {
        let plan = plan(
            subtitles: [try stream("Subtitle", index: 4, language: "eng")],
            defaultSubtitle: 4,
            carry: .init(subtitlesOff: true)
        )
        #expect(plan.automaticSubtitleOrdinal == 1)
        #expect(plan.initialSubtitleOrdinal == 0)
    }

    @Test func rememberedSubtitleOutranksCarriedOff() throws {
        let plan = plan(
            subtitles: [try stream("Subtitle", index: 4, language: "eng")],
            carry: .init(subtitlesOff: true),
            rememberedSubtitle: RememberedSubtitleChoice(language: "eng", ordinal: 1, layout: "")
        )
        #expect(plan.initialSubtitleOrdinal == 1)
    }

    @Test func benchHookOutranksEverything() throws {
        let subtitles = [
            try stream("Subtitle", index: 4, language: "eng"),
            try stream("Subtitle", index: 5, language: "jpn"),
        ]
        let remembered = RememberedSubtitleChoice(language: "eng", ordinal: 1, layout: "")
        let toJapanese = plan(subtitles: subtitles, rememberedSubtitle: remembered, bench: "jpn")
        #expect(toJapanese.initialSubtitleOrdinal == 2)
        let off = plan(subtitles: subtitles, rememberedSubtitle: remembered, bench: "off")
        #expect(off.initialSubtitleOrdinal == 0)
    }

    @Test func unmatchedSubtitleCarryFallsBackToTheViewersMode() throws {
        var settings = TrackSelectionSettings(preferredSubtitleLanguages: ["en"])
        settings.subtitleMode = .off
        let plan = plan(
            subtitles: [try stream("Subtitle", index: 4, language: "eng")],
            defaultSubtitle: 4,
            settings: settings,
            carry: .init(subtitleLanguage: "fra", subtitleDisplayTitle: "French", subtitlesOff: false)
        )
        #expect(plan.initialSubtitleOrdinal == 0)
    }

    @Test func subtitleCarryMatchesTheDisplayTitleBeforeTheLanguage() throws {
        let plan = plan(
            subtitles: [
                try stream("Subtitle", index: 4, language: "eng", displayTitle: "English - Forced", forced: true),
                try stream("Subtitle", index: 5, language: "eng", displayTitle: "English"),
            ],
            carry: .init(subtitleLanguage: "eng", subtitleDisplayTitle: "English", subtitlesOff: false)
        )
        #expect(plan.initialSubtitleOrdinal == 2)
    }

    @Test func externalServerDefaultCountsAfterEmbeddedTracks() throws {
        let plan = plan(
            subtitles: [try stream("Subtitle", index: 4, language: "eng")],
            external: [
                try stream("Subtitle", index: 8, language: "fra", external: true),
                try stream("Subtitle", index: 9, language: "deu", external: true),
            ],
            defaultSubtitle: 9
        )
        #expect(plan.initialSubtitleOrdinal == 3)
    }

    // MARK: - The system caption setting

    private func systemSubtitles() throws -> [MediaStream] {
        [
            try stream("Subtitle", index: 4, language: "eng", forced: true),
            try stream("Subtitle", index: 5, language: "eng"),
            try stream("Subtitle", index: 6, language: "eng", hearingImpaired: true),
        ]
    }

    @Test func forcedOnlyIgnoresTheServerDefault() throws {
        let plan = plan(subtitles: try systemSubtitles(), defaultSubtitle: 5, captionDisplay: .forcedOnly)
        #expect(plan.initialSubtitleOrdinal == 1)
    }

    @Test func forcedOnlyWithNoForcedTrackIsOff() throws {
        let plan = plan(
            subtitles: [try stream("Subtitle", index: 5, language: "eng")],
            captionDisplay: .forcedOnly
        )
        #expect(plan.initialSubtitleOrdinal == 0)
    }

    @Test func alwaysOnPrefersTheServerDefaultThenHearingImpaired() throws {
        let withDefault = plan(subtitles: try systemSubtitles(), defaultSubtitle: 5, captionDisplay: .alwaysOn)
        #expect(withDefault.initialSubtitleOrdinal == 2)
        let withoutDefault = plan(subtitles: try systemSubtitles(), captionDisplay: .alwaysOn)
        #expect(withoutDefault.initialSubtitleOrdinal == 3)
    }

    @Test func automaticTakesForcedSubtitlesForPreferredAudio() throws {
        let plan = plan(
            audio: [try stream("Audio", index: 1, language: "eng")],
            subtitles: try systemSubtitles(),
            defaultAudio: 1,
            captionDisplay: .automatic
        )
        #expect(plan.initialSubtitleOrdinal == 1)
    }

    @Test func automaticTurnsOnFullSubtitlesForForeignAudio() throws {
        let plan = plan(
            audio: [try stream("Audio", index: 1, language: "jpn")],
            subtitles: [
                try stream("Subtitle", index: 5, language: "eng"),
                try stream("Subtitle", index: 6, language: "eng", hearingImpaired: true),
            ],
            defaultAudio: 1,
            captionDisplay: .automatic
        )
        #expect(plan.initialSubtitleOrdinal == 2)
    }

    @Test func automaticStaysOffForPreferredAudioWithoutForcedTracks() throws {
        let plan = plan(
            audio: [try stream("Audio", index: 1, language: "eng")],
            subtitles: [try stream("Subtitle", index: 5, language: "eng")],
            defaultAudio: 1,
            captionDisplay: .automatic
        )
        #expect(plan.initialSubtitleOrdinal == 0)
    }

    @Test func unrecognizedDisplayKeepsTheServerDefault() throws {
        let plan = plan(subtitles: try systemSubtitles(), captionDisplay: .unrecognized)
        #expect(plan.initialSubtitleOrdinal == nil)
    }

    // MARK: - Recording and carrying

    @Test func audioIsNotRecordedWhenTheEngineDeliversADifferentLayout() throws {
        let plan = plan(audio: try threeAudio(), defaultAudio: 1)
        #expect(plan.audioMemoryUpdate(selected: 1, engineTrackCount: 1) == nil)
    }

    @Test func choosingTheAutomaticAudioForgetsTheOverride() throws {
        let plan = plan(audio: try threeAudio(), defaultAudio: 2)
        guard case .forget = plan.audioMemoryUpdate(selected: 2, engineTrackCount: 3) else {
            Issue.record("expected the override to be forgotten")
            return
        }
    }

    @Test func choosingAnotherAudioTrackRemembersItsDescription() throws {
        let plan = plan(audio: try threeAudio(), defaultAudio: 1)
        guard case .remember(let choice) = plan.audioMemoryUpdate(selected: 3, engineTrackCount: 3) else {
            Issue.record("expected a remembered choice")
            return
        }
        #expect(choice.language == "eng")
        #expect(choice.title == "Commentary")
        #expect(choice.ordinal == 3)
    }

    @Test func turningOffADefaultSubtitleIsRemembered() throws {
        let plan = plan(subtitles: [try stream("Subtitle", index: 4, language: "eng")], defaultSubtitle: 4)
        guard case .remember(let choice) = plan.subtitleMemoryUpdate(selected: nil, engineTrackCount: 1) else {
            Issue.record("expected off to be remembered")
            return
        }
        #expect(choice.isOff)
    }

    @Test func aSearchedSubtitleIsNotRemembered() throws {
        var plan = plan(subtitles: [try stream("Subtitle", index: 4, language: "eng")])
        plan.appendSearchedSubtitle(try stream("Subtitle", index: 99, language: "fra", external: true))
        #expect(plan.subtitleMemoryUpdate(selected: 2, engineTrackCount: 2) == nil)
    }

    @Test func carryTakesTheAudioTitleAndTheSubtitleDisplayTitle() throws {
        var plan = plan(
            audio: [try stream("Audio", index: 1, language: "eng", title: "Main", displayTitle: "AC3 - 5.1")],
            subtitles: [try stream("Subtitle", index: 4, language: "eng", displayTitle: "English")]
        )
        plan.appendSearchedSubtitle(
            try stream("Subtitle", index: 99, language: "fra", displayTitle: "French", external: true)
        )
        let carry = plan.carry(selectedAudio: 1, selectedSubtitle: 2)
        #expect(carry == .init(
            audioLanguage: "eng",
            audioTitle: "Main",
            subtitleLanguage: "fra",
            subtitleDisplayTitle: "French",
            subtitlesOff: false
        ))
        #expect(plan.carry(selectedAudio: 1, selectedSubtitle: nil).subtitlesOff)
    }

    // MARK: - Stream indexes against engine ordinals

    @Test func theServerDefaultAudioIsAStreamIndexNotAnOrdinal() throws {
        // A video stream at index 0 and a few other streams push the audio
        // indexes past their ordinals.
        let audio = [
            try stream("Audio", index: 3, language: "eng"),
            try stream("Audio", index: 4, language: "jpn"),
            try stream("Audio", index: 5, language: "deu"),
        ]
        let plan = plan(audio: audio, defaultAudio: 4)
        #expect(plan.automaticAudioOrdinal == 2)
        #expect(plan.initialAudioOrdinal == 2)
    }

    // MARK: - Audio memory across plans

    private func bareAudio(count: Int) throws -> [MediaStream] {
        try (0..<count).map { try stream("Audio", index: $0 + 1) }
    }

    @Test func anAudioPickAmongBareTracksCarriesToAPlanWithTheSameLayout() throws {
        let first = plan(audio: try bareAudio(count: 5))
        guard case .remember(let choice) = first.audioMemoryUpdate(selected: 4, engineTrackCount: 5) else {
            Issue.record("expected a remembered choice")
            return
        }
        #expect(choice.layout == AudioTrackMemoryPolicy.fingerprint(of: first.audioLayout))

        let sameLayout = plan(audio: try bareAudio(count: 5), rememberedAudio: choice)
        #expect(sameLayout.initialAudioOrdinal == 4)
        #expect(sameLayout.automaticAudioOrdinal != 4)

        // An extra track keeps ordinal 4 in range but changes the layout.
        let differentLayout = plan(audio: try bareAudio(count: 6), rememberedAudio: choice)
        #expect(differentLayout.initialAudioOrdinal == differentLayout.automaticAudioOrdinal)
        #expect(differentLayout.initialAudioOrdinal != 4)
    }

    // MARK: - Subtitle memory after a search

    @Test func aPickAmongTheOriginalSubtitlesIsStillRememberedAfterASearchAddedOne() throws {
        var plan = plan(subtitles: [
            try stream("Subtitle", index: 4, language: "eng"),
            try stream("Subtitle", index: 5, language: "fra"),
        ])
        plan.appendSearchedSubtitle(try stream("Subtitle", index: 99, language: "deu", external: true))
        guard case .remember(let choice) = plan.subtitleMemoryUpdate(selected: 2, engineTrackCount: 3) else {
            Issue.record("expected a remembered choice")
            return
        }
        #expect(choice.ordinal == 2)
        #expect(choice.language == "fra")
        #expect(choice.layout == SubtitleTrackMemoryPolicy.fingerprint(of: plan.subtitleLayout))
    }

    @Test func aSubtitleListShorterThanTheLayoutIsNotRecorded() throws {
        let plan = plan(subtitles: [
            try stream("Subtitle", index: 4, language: "eng"),
            try stream("Subtitle", index: 5, language: "fra"),
        ])
        #expect(plan.subtitleMemoryUpdate(selected: 1, engineTrackCount: 1) == nil)
    }
}
