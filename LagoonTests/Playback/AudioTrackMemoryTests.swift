import Foundation
import Testing
@testable import Lagoon

/// The case behind HEL-184: The 100's season-one remux ships five audio
/// tracks with no language, no title and no default flag — four of them
/// reading "DTS-HD MA - 5.1" — and the first is Russian. Nothing in the
/// metadata can pick the English one, so the viewer's own correction has to
/// be what carries to the next episode.
@Suite("Audio track memory")
struct AudioTrackMemoryTests {
    private func stream(
        codec: String = "dts",
        channels: Int? = 6,
        language: String? = nil,
        title: String? = nil,
        default isDefault: Bool = false
    ) -> AudioLayoutStream {
        AudioLayoutStream(
            codec: codec,
            channels: channels,
            language: language,
            title: title,
            isDefault: isDefault
        )
    }

    /// The exact season-one layout, read off the server.
    private var anonymousLayout: [AudioLayoutStream] {
        [
            stream(),
            stream(),
            stream(),
            stream(codec: "ac3", channels: 2),
            stream(),
        ]
    }

    private func choice(
        language: String? = nil,
        title: String? = nil,
        ordinal: Int,
        layout: [AudioLayoutStream]
    ) -> RememberedAudioChoice {
        RememberedAudioChoice(
            language: language,
            title: title,
            ordinal: ordinal,
            layout: AudioTrackMemoryPolicy.fingerprint(of: layout),
            updatedAt: 0
        )
    }

    @Test func positionCarriesWhenTheLayoutOffersNothingElse() {
        let remembered = choice(ordinal: 3, layout: anonymousLayout)

        #expect(AudioTrackMemoryPolicy.ordinal(
            for: remembered,
            in: anonymousLayout
        ) == 3)
    }

    /// Season two's single tagged track, against a position remembered from
    /// season one. The ordinal is in range and must still be refused,
    /// because the layout it was measured in is gone.
    @Test func aDifferentLayoutRefusesTheRememberedPosition() {
        let tagged = [
            stream(language: "rus", title: "Russian"),
            stream(language: "eng", title: "English", default: true),
            stream(language: "deu", title: "German"),
        ]
        let remembered = choice(ordinal: 3, layout: anonymousLayout)

        #expect(AudioTrackMemoryPolicy.positionalOrdinal(for: remembered, in: tagged) == nil)
        // Nor may it drift to a language rung it never had a claim on.
        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: tagged) == nil)
    }

    /// A description that names one track wins outright: the position is
    /// never consulted, even though the layout is unchanged and the stored
    /// ordinal points somewhere else entirely.
    @Test func anUnambiguousDescriptionOutranksTheRememberedPosition() {
        let layout = [
            stream(language: "rus", title: "Russian"),
            stream(language: "eng", title: "English"),
            stream(language: "deu", title: "German"),
        ]
        var remembered = choice(language: "eng", title: "English", ordinal: 2, layout: layout)
        remembered.ordinal = 1

        #expect(AudioTrackMemoryPolicy.positionalOrdinal(for: remembered, in: layout) == 1)
        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: layout) == 2)
    }

    /// One tagged track and three bare ones: the viewer's pick among the
    /// bare three cannot be described, so position has to carry it.
    @Test func positionCarriesABareTrackAmongTaggedOnes() {
        let layout = [
            stream(language: "eng", title: "English", default: true),
            stream(),
            stream(),
            stream(),
        ]
        let remembered = choice(ordinal: 3, layout: layout)

        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: layout) == 3)
    }

    /// Two tracks tagged identically. Description cannot separate them, so
    /// without the positional rung the viewer's move to the second one
    /// would silently snap back to the first on the next episode.
    @Test func positionSeparatesIdenticallyTaggedTracks() {
        let layout = [
            stream(language: "eng", title: "English"),
            stream(codec: "ac3", channels: 2, language: "eng", title: "English"),
        ]
        let remembered = choice(language: "eng", title: "English", ordinal: 2, layout: layout)

        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: layout) == 2)
    }

    /// Where the layout has changed and description is ambiguous, the right
    /// language is the most that can be promised.
    @Test func anAmbiguousDescriptionFallsBackToTheRightLanguage() {
        let remembered = choice(
            language: "eng",
            title: "English",
            ordinal: 2,
            layout: [stream(language: "eng", title: "English")]
        )
        let changed = [
            stream(language: "rus", title: "Russian"),
            stream(language: "eng", title: "English"),
            stream(codec: "ac3", channels: 2, language: "eng", title: "English"),
        ]

        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: changed) == 2)
    }

    @Test func aChangedLayoutRetiresTheRememberedPosition() {
        // An extra commentary track shifts everything below it, so the
        // stored ordinal no longer names what the viewer picked.
        let remembered = choice(ordinal: 3, layout: anonymousLayout)
        let withCommentary = anonymousLayout + [stream(channels: 2)]

        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: withCommentary) == nil)
    }

    @Test func languageIdentifiesTheTrackAheadOfAnyPosition() {
        let layout = [
            stream(language: "rus", title: "Russian"),
            stream(language: "eng", title: "English"),
        ]
        let remembered = choice(language: "eng", title: "English", ordinal: 2, layout: layout)
        // Re-tagged release: the same track, now in a different position.
        let reordered = [
            stream(language: "eng", title: "English"),
            stream(language: "rus", title: "Russian"),
        ]

        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: reordered) == 1)
    }

    /// Jellyfin synthesizes a display title from codec and channel layout
    /// when a file carries none, so four untagged tracks all "display" the
    /// same. Matching on that would always land on the first — the bug that
    /// made autoplay reinstate Russian even after a correction.
    @Test func aSharedTitleIdentifiesNothing() {
        let layout = [
            stream(title: "DTS-HD MA - 5.1"),
            stream(title: "DTS-HD MA - 5.1"),
            stream(title: "DTS-HD MA - 5.1"),
        ]

        #expect(AudioTrackMemoryPolicy.uniqueDescriptiveOrdinal(
            matchingLanguage: nil,
            title: "DTS-HD MA - 5.1",
            in: layout
        ) == nil)
        // And the in-session carry, which has no fingerprint to fall back
        // on, must not quietly answer with the first of them either.
        #expect(AudioTrackMemoryPolicy.descriptiveOrdinal(
            matchingLanguage: nil,
            title: "DTS-HD MA - 5.1",
            in: layout
        ) == nil)
    }

    @Test func aUniqueTitleStillIdentifiesItsTrack() {
        let layout = [stream(title: "Commentary"), stream(title: "Feature")]

        #expect(AudioTrackMemoryPolicy.uniqueDescriptiveOrdinal(
            matchingLanguage: nil,
            title: "Feature",
            in: layout
        ) == 2)
    }

    /// A layout that lost tracks since the choice was made. The fingerprint
    /// already refuses it, but the range check is the backstop that keeps a
    /// stale ordinal from indexing past the end.
    @Test func anOrdinalPastTheEndIsRefused() {
        let shorter = Array(anonymousLayout.prefix(2))
        let remembered = RememberedAudioChoice(
            language: nil,
            title: nil,
            ordinal: 5,
            layout: AudioTrackMemoryPolicy.fingerprint(of: shorter),
            updatedAt: 0
        )

        #expect(AudioTrackMemoryPolicy.positionalOrdinal(for: remembered, in: shorter) == nil)
        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: shorter) == nil)
    }

    /// The separators are not sacred: a title may contain them, and two
    /// different layouts hashing alike is the one way a position could be
    /// applied to a layout it was never measured in.
    @Test func fingerprintsSurviveSeparatorsInsideTitles() {
        let left = [stream(title: "a/b"), stream(title: "c")]
        let right = [stream(title: "a"), stream(title: "b/c")]

        #expect(
            AudioTrackMemoryPolicy.fingerprint(of: left)
                != AudioTrackMemoryPolicy.fingerprint(of: right)
        )
    }

    /// What a viewer's change does to the stored choice. Moving off the
    /// automatic pick stores an override; landing back on it drops one,
    /// because keeping it would freeze the show against a later change of
    /// preferences.
    @Test func onlyAMoveAwayFromAutomaticSelectionIsStored() {
        #expect(
            AudioTrackMemoryPolicy.outcome(chosen: 3, automatic: 1) == .remember(ordinal: 3)
        )
        #expect(AudioTrackMemoryPolicy.outcome(chosen: 1, automatic: 1) == .forget)
        // No automatic choice at all: the engine starts such a layout on
        // its first track, so that is what returning to it means.
        #expect(AudioTrackMemoryPolicy.outcome(chosen: 1, automatic: nil) == .forget)
        #expect(
            AudioTrackMemoryPolicy.outcome(chosen: 2, automatic: nil) == .remember(ordinal: 2)
        )
    }

    @Test func anEmptyLayoutCarriesNothing() {
        #expect(AudioTrackMemoryPolicy.ordinal(for: choice(ordinal: 1, layout: []), in: []) == nil)
    }

    @Test func fingerprintFollowsShapeNotCountAlone() {
        // Same count, different shape: the stereo track moved.
        let shuffled = [
            stream(codec: "ac3", channels: 2),
            stream(),
            stream(),
            stream(),
            stream(),
        ]
        #expect(
            AudioTrackMemoryPolicy.fingerprint(of: anonymousLayout)
                != AudioTrackMemoryPolicy.fingerprint(of: shuffled)
        )
    }

    /// Each test gets its own suite, removed afterwards so the test host's
    /// container does not accumulate them.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "hel184.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    @Test func aRememberedChoiceOutlivesTheStoreThatWroteIt() throws {
        try withDefaults { defaults in
            let scope = AudioTrackMemoryStore.scope(seriesID: "series-1", itemID: "episode-1")
            let remembered = choice(ordinal: 3, layout: anonymousLayout)

            let writing = AudioTrackMemoryStore(defaults: defaults)
            writing.configure(accountID: "account")
            writing.remember(remembered, for: scope)

            // A new presentation builds a new store: the point of persisting.
            let reading = AudioTrackMemoryStore(defaults: defaults)
            reading.configure(accountID: "account")
            #expect(reading.choice(for: scope) == remembered)

            // And another account must not inherit it.
            let other = AudioTrackMemoryStore(defaults: defaults)
            other.configure(accountID: "other-account")
            #expect(other.choice(for: scope) == nil)
        }
    }

    /// Two players open over one account, which Picture in Picture makes
    /// ordinary. Each store writes the whole map, so one must not carry the
    /// other's entries away with it.
    @MainActor
    @Test func aSecondStoreDoesNotClobberTheFirstsEntries() throws {
        try withDefaults { defaults in
            let first = AudioTrackMemoryStore(defaults: defaults)
            first.configure(accountID: "account")
            let second = AudioTrackMemoryStore(defaults: defaults)
            second.configure(accountID: "account")

            first.remember(choice(ordinal: 3, layout: anonymousLayout), for: "series-1")
            second.remember(choice(ordinal: 2, layout: anonymousLayout), for: "series-2")

            let reading = AudioTrackMemoryStore(defaults: defaults)
            reading.configure(accountID: "account")
            #expect(reading.choice(for: "series-1")?.ordinal == 3)
            #expect(reading.choice(for: "series-2")?.ordinal == 2)
        }
    }

    /// The oldest entries fall off, and never the one just written, however
    /// the clock has behaved.
    @MainActor
    @Test func theStoreEvictsOldestFirstAndKeepsTheNewestWrite() throws {
        try withDefaults { defaults in
            let store = AudioTrackMemoryStore(defaults: defaults)
            store.configure(accountID: "account")
            for index in 0..<200 {
                var entry = choice(ordinal: 1, layout: anonymousLayout)
                entry.updatedAt = Double(index + 1)
                store.remember(entry, for: "series-\(index)")
            }

            // Written with the oldest timestamp of all, so a naive eviction
            // would drop exactly this one.
            var newest = choice(ordinal: 4, layout: anonymousLayout)
            newest.updatedAt = 0
            store.remember(newest, for: "series-new")

            #expect(store.choice(for: "series-new")?.ordinal == 4)
            // The genuinely oldest entry went instead.
            #expect(store.choice(for: "series-0") == nil)
            #expect(store.choice(for: "series-199")?.ordinal == 1)
        }
    }

    @MainActor
    @Test func everyEpisodeOfAShowSharesOneChoice() {
        #expect(
            AudioTrackMemoryStore.scope(seriesID: "series-1", itemID: "episode-1")
                == AudioTrackMemoryStore.scope(seriesID: "series-1", itemID: "episode-2")
        )
        // A film answers only for itself.
        #expect(
            AudioTrackMemoryStore.scope(seriesID: nil, itemID: "film-1")
                != AudioTrackMemoryStore.scope(seriesID: nil, itemID: "film-2")
        )
    }

    /// The other half of the same problem: four rows reading "DTS 5.1"
    /// leave the viewer nothing to pick by, or to recognise afterwards.
    @Test func collidingTrackNamesGainTheirPositionAndUniqueOnesDoNot() {
        let tracks = [
            PlayerTrack(engineID: 1, kind: .audio, displayName: "DTS 5.1", isSelected: false),
            PlayerTrack(engineID: 2, kind: .audio, displayName: "DTS 5.1", isSelected: true),
            PlayerTrack(engineID: 3, kind: .audio, displayName: "DTS 5.1", isSelected: false),
            PlayerTrack(
                engineID: 4,
                kind: .audio,
                displayName: "Dolby Digital Stereo",
                isSelected: false
            ),
        ]

        let named = SampleBufferPlayerEngine.disambiguated(tracks)

        #expect(named.map(\.displayName) == [
            "DTS 5.1 · Track 1",
            "DTS 5.1 · Track 2",
            "DTS 5.1 · Track 3",
            "Dolby Digital Stereo",
        ])
        // Ordinals and selection are what the engine acts on: renaming must
        // not disturb either.
        #expect(named.map(\.engineID) == [1, 2, 3, 4])
        #expect(named.filter(\.isSelected).map(\.engineID) == [2])
    }

    @Test func namesThatAreAlreadyDistinctAreLeftAlone() {
        let tracks = [
            PlayerTrack(engineID: 1, kind: .audio, displayName: "English", isSelected: true),
            PlayerTrack(engineID: 2, kind: .audio, displayName: "Russian", isSelected: false),
        ]

        #expect(SampleBufferPlayerEngine.disambiguated(tracks) == tracks)
    }

    @MainActor
    @Test func forgettingAChoiceClearsItFromDiskToo() throws {
        try withDefaults { defaults in
            let scope = AudioTrackMemoryStore.scope(seriesID: "series-1", itemID: "episode-1")
            let store = AudioTrackMemoryStore(defaults: defaults)
            store.configure(accountID: "account")

            store.remember(choice(ordinal: 3, layout: anonymousLayout), for: scope)
            store.forget(scope)

            #expect(store.choice(for: scope) == nil)
            let reading = AudioTrackMemoryStore(defaults: defaults)
            reading.configure(accountID: "account")
            #expect(reading.choice(for: scope) == nil)
        }
    }
}
