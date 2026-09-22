import Foundation
import Testing
@testable import Lagoon

/// The audio memory's counterpart: the subtitle choice survives closing the player.
@Suite("Subtitle track memory")
struct SubtitleTrackMemoryTests {
    private func stream(
        language: String? = nil,
        title: String? = nil,
        forced: Bool = false,
        hearingImpaired: Bool = false,
        external: Bool = false,
        default isDefault: Bool = false
    ) -> SubtitleLayoutStream {
        SubtitleLayoutStream(
            language: language,
            title: title,
            isForced: forced,
            isHearingImpaired: hearingImpaired,
            isExternal: external,
            isDefault: isDefault
        )
    }

    /// A release that says "English" three times: full, forced and SDH.
    private var englishThreeWays: [SubtitleLayoutStream] {
        [
            stream(language: "eng", title: "English"),
            stream(language: "eng", title: "English", forced: true),
            stream(language: "eng", title: "English", hearingImpaired: true),
        ]
    }

    private func choice(
        off: Bool = false,
        language: String? = nil,
        title: String? = nil,
        ordinal: Int,
        layout: [SubtitleLayoutStream]
    ) -> RememberedSubtitleChoice {
        RememberedSubtitleChoice(
            isOff: off,
            language: language,
            title: title,
            ordinal: ordinal,
            layout: SubtitleTrackMemoryPolicy.fingerprint(of: layout),
            updatedAt: 0
        )
    }

    @Test func offIsAnAnswerAndSurvivesAnyLayout() {
        let remembered = choice(off: true, ordinal: 0, layout: englishThreeWays)
        #expect(SubtitleTrackMemoryPolicy.ordinal(for: remembered, in: englishThreeWays) == 0)
        // Off names no track, so no layout change can retire it.
        #expect(SubtitleTrackMemoryPolicy.ordinal(for: remembered, in: []) == 0)
        #expect(
            SubtitleTrackMemoryPolicy.ordinal(
                for: remembered,
                in: [stream(language: "fin", title: "Finnish")]
            ) == 0
        )
    }

    @Test func aUniqueLanguageIdentifiesItsTrackAheadOfAnyPosition() {
        let layout = [
            stream(language: "fin", title: "Finnish"),
            stream(language: "eng", title: "English"),
        ]
        // Stored as the second track; here the languages have swapped over.
        let remembered = choice(language: "eng", title: "English", ordinal: 2, layout: layout)
        let swapped = [
            stream(language: "eng", title: "English"),
            stream(language: "fin", title: "Finnish"),
        ]
        #expect(SubtitleTrackMemoryPolicy.ordinal(for: remembered, in: swapped) == 1)
    }

    @Test func positionSeparatesIdenticallyTaggedTracks() {
        // Description names all three, so only the position can say SDH.
        let remembered = choice(
            language: "eng",
            title: "English",
            ordinal: 3,
            layout: englishThreeWays
        )
        #expect(SubtitleTrackMemoryPolicy.ordinal(for: remembered, in: englishThreeWays) == 3)
    }

    @Test func aChangedLayoutRetiresTheRememberedPosition() {
        let remembered = choice(
            language: "eng",
            title: "English",
            ordinal: 3,
            layout: englishThreeWays
        )
        // The SDH track is gone, so the position is refused and language answers.
        let shorter = [
            stream(language: "eng", title: "English"),
            stream(language: "eng", title: "English", forced: true),
        ]
        #expect(SubtitleTrackMemoryPolicy.positionalOrdinal(for: remembered, in: shorter) == nil)
        #expect(SubtitleTrackMemoryPolicy.ordinal(for: remembered, in: shorter) == 1)
    }

    /// The flags are part of the layout: gaining an SDH marking retires a
    /// stored position.
    @Test func fingerprintFollowsTheFlagsNotJustTheNames() {
        let tagged = [
            stream(language: "eng", title: "English"),
            stream(language: "eng", title: "English", hearingImpaired: true),
        ]
        let untagged = [
            stream(language: "eng", title: "English"),
            stream(language: "eng", title: "English"),
        ]
        #expect(
            SubtitleTrackMemoryPolicy.fingerprint(of: tagged)
                != SubtitleTrackMemoryPolicy.fingerprint(of: untagged)
        )
        // Nor are a sidecar and an embedded track of the same name.
        let external = [
            stream(language: "eng", title: "English"),
            stream(language: "eng", title: "English", external: true),
        ]
        #expect(
            SubtitleTrackMemoryPolicy.fingerprint(of: external)
                != SubtitleTrackMemoryPolicy.fingerprint(of: untagged)
        )
    }

    @Test func fingerprintsSurviveSeparatorsInsideTitles() {
        let first = [stream(language: "en", title: "g|3:lish"), stream(language: "fi")]
        let second = [stream(language: "eng", title: "lish"), stream(language: "fi")]
        #expect(
            SubtitleTrackMemoryPolicy.fingerprint(of: first)
                != SubtitleTrackMemoryPolicy.fingerprint(of: second)
        )
    }

    @Test func onlyAMoveAwayFromAutomaticSelectionIsStored() {
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 2, automatic: 2) == .forget)
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 3, automatic: 2) == .remember(ordinal: 3))
    }

    /// Nil means the engine starts with subtitles off, so choosing off there
    /// overrides nothing. Off against a server default is a real choice.
    @Test func turningSubtitlesOffIsStoredOnlyWhereItOverrulesSomething() {
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 0, automatic: nil) == .forget)
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 0, automatic: 1) == .remember(ordinal: 0))
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 1, automatic: nil) == .remember(ordinal: 1))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "hel206.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    @Test func aRememberedChoiceOutlivesTheStoreThatWroteIt() throws {
        try withDefaults { defaults in
            let scope = SubtitleTrackMemoryStore.scope(seriesID: "series-1", itemID: "episode-1")
            let remembered = choice(off: true, ordinal: 0, layout: englishThreeWays)

            let writing = SubtitleTrackMemoryStore(defaults: defaults)
            writing.configure(accountID: "account")
            writing.remember(remembered, for: scope)

            let reading = SubtitleTrackMemoryStore(defaults: defaults)
            reading.configure(accountID: "account")
            #expect(reading.choice(for: scope) == remembered)
        }
    }

    /// The audio and subtitle memories share a mechanism but not a key.
    @MainActor
    @Test func subtitlesAndAudioAreStoredApart() throws {
        try withDefaults { defaults in
            let scope = SubtitleTrackMemoryStore.scope(seriesID: "series-1", itemID: "episode-1")
            let subtitles = SubtitleTrackMemoryStore(defaults: defaults)
            subtitles.configure(accountID: "account")
            subtitles.remember(
                choice(language: "eng", title: "English", ordinal: 1, layout: englishThreeWays),
                for: scope
            )

            let audio = AudioTrackMemoryStore(defaults: defaults)
            audio.configure(accountID: "account")
            #expect(audio.choice(for: scope) == nil)
        }
    }
}
