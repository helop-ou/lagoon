import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// A real remux ships five audio tracks with no language, title or default
/// flag, and the first is Russian. Only the viewer's own correction can carry
/// the English one to the next episode.
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

    /// That layout, as read off the server.
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

    /// The ordinal is in range but must be refused: its layout is gone.
    @Test func aDifferentLayoutRefusesTheRememberedPosition() {
        let tagged = [
            stream(language: "rus", title: "Russian"),
            stream(language: "eng", title: "English", default: true),
            stream(language: "deu", title: "German"),
        ]
        let remembered = choice(ordinal: 3, layout: anonymousLayout)

        #expect(AudioTrackMemoryPolicy.positionalOrdinal(for: remembered, in: tagged) == nil)
        // Nor may it fall through to a language match.
        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: tagged) == nil)
    }

    /// A description that names one track wins over the stored position.
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

    /// A pick among bare tracks cannot be described, so position carries it.
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

    /// Identical tags cannot separate two tracks, so position must, or the
    /// choice snaps back to the first.
    @Test func positionSeparatesIdenticallyTaggedTracks() {
        let layout = [
            stream(language: "eng", title: "English"),
            stream(codec: "ac3", channels: 2, language: "eng", title: "English"),
        ]
        let remembered = choice(language: "eng", title: "English", ordinal: 2, layout: layout)

        #expect(AudioTrackMemoryPolicy.ordinal(for: remembered, in: layout) == 2)
    }

    /// A changed layout with an ambiguous description gets the right language.
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
        // An extra track shifts the ordinals.
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

    /// Jellyfin synthesizes a title from codec and channels when a file has
    /// none, so untagged tracks share it. Matching on it always picks the first.
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
        // The in-session carry has no fingerprint, so it must refuse too.
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

    /// A backstop behind the fingerprint: a stale ordinal never indexes past the end.
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

    /// A title may contain a separator; two layouts hashing alike would
    /// apply a position to the wrong layout.
    @Test func fingerprintsSurviveSeparatorsInsideTitles() {
        let left = [stream(title: "a/b"), stream(title: "c")]
        let right = [stream(title: "a"), stream(title: "b/c")]

        #expect(
            AudioTrackMemoryPolicy.fingerprint(of: left)
                != AudioTrackMemoryPolicy.fingerprint(of: right)
        )
    }

    /// Returning to the automatic pick drops the override, so a later
    /// preference change still applies.
    @Test func onlyAMoveAwayFromAutomaticSelectionIsStored() {
        #expect(
            AudioTrackMemoryPolicy.outcome(chosen: 3, automatic: 1) == .remember(ordinal: 3)
        )
        #expect(AudioTrackMemoryPolicy.outcome(chosen: 1, automatic: 1) == .forget)
        // No automatic choice: the engine starts on the first track.
        #expect(AudioTrackMemoryPolicy.outcome(chosen: 1, automatic: nil) == .forget)
        #expect(
            AudioTrackMemoryPolicy.outcome(chosen: 2, automatic: nil) == .remember(ordinal: 2)
        )
    }

    @Test func anEmptyLayoutCarriesNothing() {
        #expect(AudioTrackMemoryPolicy.ordinal(for: choice(ordinal: 1, layout: []), in: []) == nil)
    }

    @Test func fingerprintFollowsShapeNotCountAlone() {
        // The stereo track moved.
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

            // A new presentation builds a new store.
            let reading = AudioTrackMemoryStore(defaults: defaults)
            reading.configure(accountID: "account")
            #expect(reading.choice(for: scope) == remembered)

            let other = AudioTrackMemoryStore(defaults: defaults)
            other.configure(accountID: "other-account")
            #expect(other.choice(for: scope) == nil)
        }
    }

    /// Picture in Picture can open two players on one account. Each store
    /// writes the whole map, so neither may drop the other's entries.
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

    /// Evicts oldest first, but never the entry just written, whatever the clock says.
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

            // The oldest timestamp of all.
            var newest = choice(ordinal: 4, layout: anonymousLayout)
            newest.updatedAt = 0
            store.remember(newest, for: "series-new")

            #expect(store.choice(for: "series-new")?.ordinal == 4)
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
        #expect(
            AudioTrackMemoryStore.scope(seriesID: nil, itemID: "film-1")
                != AudioTrackMemoryStore.scope(seriesID: nil, itemID: "film-2")
        )
    }

    /// Identical track names give the viewer nothing to pick by.
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
        // Renaming leaves ordinals and selection alone.
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
