import Foundation
import LagoonEngine

/// One audio stream reduced to what identifies it again in a sibling
/// episode. Unlike `TrackSelectionCandidate`, codec and channels are here:
/// they must never choose a track, but they describe the layout's shape,
/// which decides whether a remembered position still applies.
nonisolated struct AudioLayoutStream: Equatable, TrackLayoutEntry {
    let codec: String?
    let channels: Int?
    let language: String?
    let title: String?
    let isDefault: Bool

    init(
        codec: String?,
        channels: Int?,
        language: String?,
        title: String?,
        isDefault: Bool = false
    ) {
        self.codec = codec
        self.channels = channels
        self.language = language
        self.title = title
        self.isDefault = isDefault
    }
}

/// An audio choice the viewer made, kept across player presentations.
/// `language`/`title` survive a layout change; `ordinal` is the fallback for
/// tracks that cannot be told apart, valid only against its `layout`.
nonisolated struct RememberedAudioChoice: RememberedTrackChoice {
    static let memoryNamespace = "audioTrackMemory"

    var language: String?
    var title: String?
    /// 1-based, in the engine's embedded-audio ordinal space.
    var ordinal: Int
    /// Fingerprint of the layout the ordinal was measured against.
    var layout: String
    var updatedAt: Double

    init(
        language: String?,
        title: String?,
        ordinal: Int,
        layout: String,
        updatedAt: Double = Date.timeIntervalSinceReferenceDate
    ) {
        self.language = language
        self.title = title
        self.ordinal = ordinal
        self.layout = layout
        self.updatedAt = updatedAt
    }
}

/// How a remembered choice matches the item about to play, and how a fresh
/// choice updates it.
///
/// Order matters: an unambiguous description outranks automatic selection.
/// A position comes next, and only against an identical layout, so it never
/// overrules a description that identifies a track.
nonisolated enum AudioTrackMemoryPolicy {
    /// Stable description of a layout's shape. Language, title and the default
    /// flag count, so a release that gains proper tagging is a new layout.
    static func fingerprint(of streams: [AudioLayoutStream]) -> String {
        TrackLayoutFingerprint.of(streams.map { stream in
            [
                stream.codec ?? "",
                stream.channels.map(String.init) ?? "",
                stream.language ?? "",
                stream.title ?? "",
                stream.isDefault ? "d" : "",
            ]
        })
    }

    /// The ordinal when the description names exactly one track, else nil.
    static func uniqueDescriptiveOrdinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        TrackLayoutMatch.uniqueDescriptiveOrdinal(
            matchingLanguage: language, title: title, in: streams)
    }

    /// Last resort: the first track of the right language.
    static func approximateDescriptiveOrdinal(
        matchingLanguage language: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        TrackLayoutMatch.approximateDescriptiveOrdinal(matchingLanguage: language, in: streams)
    }

    /// Description alone, for the in-session carry between episodes, which has
    /// no layout fingerprint.
    static func descriptiveOrdinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        uniqueDescriptiveOrdinal(matchingLanguage: language, title: title, in: streams)
            ?? approximateDescriptiveOrdinal(matchingLanguage: language, in: streams)
    }

    /// Position, fenced by an identical layout.
    static func positionalOrdinal(
        for choice: RememberedAudioChoice,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        TrackLayoutMatch.positionalOrdinal(
            for: choice, in: streams, fingerprint: fingerprint(of: streams))
    }

    /// The whole ladder: unambiguous description, position against an unchanged
    /// layout, then the right language.
    static func ordinal(
        for choice: RememberedAudioChoice,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        uniqueDescriptiveOrdinal(
            matchingLanguage: choice.language,
            title: choice.title,
            in: streams
        )
            ?? positionalOrdinal(for: choice, in: streams)
            ?? approximateDescriptiveOrdinal(matchingLanguage: choice.language, in: streams)
    }

    /// What a viewer's track change does to the stored choice.
    ///
    /// Landing back on the automatic choice drops the override, or the show
    /// would stay frozen against later preference changes. `automatic` is nil
    /// when policy named no track; the engine then starts on the first track.
    typealias Outcome = TrackMemoryOutcome

    static func outcome(chosen ordinal: Int, automatic: Int?) -> Outcome {
        ordinal == (automatic ?? 1) ? .forget : .remember(ordinal: ordinal)
    }
}

/// The audio half of `TrackMemoryStore`. The namespace is what shipped, so
/// it must not change.
typealias AudioTrackMemoryStore = TrackMemoryStore<RememberedAudioChoice>
