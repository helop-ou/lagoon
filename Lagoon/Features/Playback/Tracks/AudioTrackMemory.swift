import Foundation
import LagoonEngine

/// One audio stream reduced to what identifies it again in a sibling
/// episode. Unlike `TrackSelectionCandidate`, codec and channels are here:
/// they must never choose a track, but they describe the layout's shape,
/// which decides whether a remembered position still applies.
nonisolated struct AudioLayoutStream: Equatable {
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
    /// Ambiguity is failure: Jellyfin synthesizes titles from codec and
    /// channels, so several tracks can share one.
    static func uniqueDescriptiveOrdinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        guard language != nil || title != nil else { return nil }
        let exact = streams.indices.filter {
            streams[$0].language == language && streams[$0].title == title
        }
        if exact.count == 1 { return exact[0] + 1 }
        // Titles pick up episode noise ("English (SDH) - Forced"), so fall back to
        // language, but only where it names one track.
        guard exact.isEmpty, let language else { return nil }
        let byLanguage = streams.indices.filter { streams[$0].language == language }
        return byLanguage.count == 1 ? byLanguage[0] + 1 : nil
    }

    /// Last resort: the first track of the right language.
    static func approximateDescriptiveOrdinal(
        matchingLanguage language: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
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

    /// Position, fenced by an identical layout. Reached only after description
    /// fails, so it covers untagged releases and ones that tag several tracks
    /// alike.
    static func positionalOrdinal(
        for choice: RememberedAudioChoice,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        guard !streams.isEmpty,
              choice.layout == fingerprint(of: streams),
              (1...streams.count).contains(choice.ordinal) else { return nil }
        return choice.ordinal
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
    enum Outcome: Equatable {
        case remember(ordinal: Int)
        case forget
    }

    static func outcome(chosen ordinal: Int, automatic: Int?) -> Outcome {
        ordinal == (automatic ?? 1) ? .forget : .remember(ordinal: ordinal)
    }
}

/// The audio half of `TrackMemoryStore`. The namespace is what shipped, so
/// it must not change.
typealias AudioTrackMemoryStore = TrackMemoryStore<RememberedAudioChoice>
