import Foundation
import Testing
@testable import Lagoon

/// The same ask as the audio memory, for the other track list. Subtitles
/// carried within a sitting already; closing the player threw the choice
/// away, so a show tagged badly — or simply watched with subtitles on — had
/// to be corrected again every time.
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
        // Off describes no track, so a layout it was never measured in
        // cannot retire it — which is the whole point of the answer.
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
        // This episode's SDH track is gone; the position would now name the
        // forced one, so it is refused and language alone answers instead.
        let shorter = [
            stream(language: "eng", title: "English"),
            stream(language: "eng", title: "English", forced: true),
        ]
        #expect(SubtitleTrackMemoryPolicy.positionalOrdinal(for: remembered, in: shorter) == nil)
        #expect(SubtitleTrackMemoryPolicy.ordinal(for: remembered, in: shorter) == 1)
    }

    /// The flags are what make a layout's shape here. A release that gains
    /// an SDH marking is a different layout, and a position measured before
    /// it should no longer apply.
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
        // A sidecar and an embedded track of the same name are not the
        // same track either.
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

    /// Nil is policy naming no track, which is the engine starting with
    /// subtitles off. Turning them off there overrides nothing; turning
    /// them off against a server default that had them on is as deliberate
    /// a choice as picking a track.
    @Test func turningSubtitlesOffIsStoredOnlyWhereItOverrulesSomething() {
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 0, automatic: nil) == .forget)
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 0, automatic: 1) == .remember(ordinal: 0))
        #expect(SubtitleTrackMemoryPolicy.outcome(chosen: 1, automatic: nil) == .remember(ordinal: 1))
    }

    /// Each test gets its own suite, removed afterwards so the test host's
    /// container does not accumulate them.
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

    /// The two memories share a mechanism and must not share a key: a show
    /// can have a remembered audio track and no remembered subtitle, and
    /// one store reading the other's payload would decode nothing anyway.
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
