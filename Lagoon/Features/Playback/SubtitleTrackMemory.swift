import Foundation

/// One subtitle stream reduced to what identifies it again in a sibling
/// episode.
///
/// The flags are here for the same reason codec and channels are in
/// `AudioLayoutStream`: they describe the shape of a layout, and it is the
/// shape — not any one stream — that decides whether a remembered position
/// still means anything. Forced, hearing-impaired and external are exactly
/// the distinctions a release makes between tracks that otherwise share a
/// language.
nonisolated struct SubtitleLayoutStream: Equatable {
    let language: String?
    let title: String?
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool
    let isDefault: Bool

    init(
        language: String?,
        title: String?,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        isExternal: Bool = false,
        isDefault: Bool = false
    ) {
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isExternal = isExternal
        self.isDefault = isDefault
    }
}

/// A subtitle choice the viewer made, durable across player presentations.
///
/// `isOff` is the difference from `RememberedAudioChoice`. There is no such
/// thing as no audio, but "no subtitles" is a deliberate answer and the one
/// a server default is most likely to overrule on the next episode, so it
/// is remembered like any other.
nonisolated struct RememberedSubtitleChoice: RememberedTrackChoice {
    static let memoryNamespace = "subtitleTrackMemory"

    var isOff: Bool
    var language: String?
    var title: String?
    /// 1-based, in the engine's subtitle ordinal space: embedded tracks
    /// first, then the external ones, with 0 meaning no subtitles.
    var ordinal: Int
    /// Fingerprint of the layout the ordinal was measured against. A
    /// position means nothing against a different one.
    var layout: String
    /// Reference-date seconds, used only to evict the oldest entries.
    /// Deliberately not a `Date`: the codebase keeps dates out of Codable.
    var updatedAt: Double

    init(
        isOff: Bool = false,
        language: String? = nil,
        title: String? = nil,
        ordinal: Int,
        layout: String,
        updatedAt: Double = Date.timeIntervalSinceReferenceDate
    ) {
        self.isOff = isOff
        self.language = language
        self.title = title
        self.ordinal = ordinal
        self.layout = layout
        self.updatedAt = updatedAt
    }
}

/// How a remembered subtitle choice is matched against the item about to
/// play, and what a fresh choice should do to the stored one.
///
/// The same ladder as `AudioTrackMemoryPolicy`, and for the same reasons: a
/// track named unambiguously by its own metadata is an explicit choice and
/// outranks automatic selection; a *position* speaks next, and only against
/// a layout identical to the one the choice was made in. Kept apart from
/// the audio policy rather than generalized with it, because the two differ
/// exactly where it matters — what makes a layout's shape, and the fact
/// that off is an answer here.
nonisolated enum SubtitleTrackMemoryPolicy {
    /// The engine's ordinal for "no subtitles".
    static let offOrdinal = 0

    /// Stable description of a layout's shape.
    static func fingerprint(of streams: [SubtitleLayoutStream]) -> String {
        TrackLayoutFingerprint.of(streams.map { stream in
            [
                stream.language ?? "",
                stream.title ?? "",
                stream.isForced ? "f" : "",
                stream.isHearingImpaired ? "h" : "",
                stream.isExternal ? "x" : "",
                stream.isDefault ? "d" : "",
            ]
        })
    }

    /// Where the choice lands when its description names exactly one track
    /// here, or nil. Ambiguity is failure, not a coin flip: a release that
    /// ships "English" three times over — full, forced and SDH — identifies
    /// none of them by language alone.
    static func uniqueDescriptiveOrdinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [SubtitleLayoutStream]
    ) -> Int? {
        guard language != nil || title != nil else { return nil }
        let exact = streams.indices.filter {
            streams[$0].language == language && streams[$0].title == title
        }
        if exact.count == 1 { return exact[0] + 1 }
        guard exact.isEmpty, let language else { return nil }
        let byLanguage = streams.indices.filter { streams[$0].language == language }
        return byLanguage.count == 1 ? byLanguage[0] + 1 : nil
    }

    /// The best remaining guess once description has failed to be
    /// unambiguous: the first track of the right language. Possibly the
    /// forced one where the viewer meant the full one, but never a language
    /// they cannot read.
    static func approximateDescriptiveOrdinal(
        matchingLanguage language: String?,
        in streams: [SubtitleLayoutStream]
    ) -> Int? {
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
    }

    /// Position, fenced by an identical layout.
    ///
    /// Reached only after description has failed to name one track, so it
    /// cannot overrule a real signal.
    static func positionalOrdinal(
        for choice: RememberedSubtitleChoice,
        in streams: [SubtitleLayoutStream]
    ) -> Int? {
        guard !streams.isEmpty,
              choice.layout == fingerprint(of: streams),
              (1...streams.count).contains(choice.ordinal) else { return nil }
        return choice.ordinal
    }

    /// The whole ladder. Off answers immediately: it describes no track, so
    /// there is nothing for the rungs below to match, and it is as true of
    /// a layout that changed as of the one it was chosen in.
    static func ordinal(
        for choice: RememberedSubtitleChoice,
        in streams: [SubtitleLayoutStream]
    ) -> Int? {
        if choice.isOff { return offOrdinal }
        return uniqueDescriptiveOrdinal(
            matchingLanguage: choice.language,
            title: choice.title,
            in: streams
        )
            ?? positionalOrdinal(for: choice, in: streams)
            ?? approximateDescriptiveOrdinal(matchingLanguage: choice.language, in: streams)
    }

    /// What a viewer's subtitle change should do to the stored choice.
    ///
    /// `automatic` is nil where policy named no track, which is the engine
    /// starting with subtitles off — so a viewer who turns them off there
    /// has made no override, and one who turns them off against a server
    /// default has made a very deliberate one.
    enum Outcome: Equatable {
        /// Ordinal 0 is the viewer choosing no subtitles.
        case remember(ordinal: Int)
        case forget
    }

    static func outcome(chosen ordinal: Int, automatic: Int?) -> Outcome {
        ordinal == (automatic ?? offOrdinal) ? .forget : .remember(ordinal: ordinal)
    }
}

/// The subtitle half of `TrackMemoryStore`, written under
/// `playback.subtitleTrackMemory.<account>`.
typealias SubtitleTrackMemoryStore = TrackMemoryStore<RememberedSubtitleChoice>
