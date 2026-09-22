import Foundation
import LagoonEngine

/// One audio stream reduced to what identifies it again in a sibling
/// episode.
///
/// Codec and channel count are here, unlike `TrackSelectionCandidate`,
/// which deliberately leaves them out because they must never *choose* a
/// track. They earn their place for the opposite reason: together they
/// describe the shape of a layout, and it is the shape — not any one
/// stream — that decides whether a remembered position still means
/// anything.
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

/// An audio choice the viewer made, durable across player presentations.
///
/// Both halves matter. `language`/`title` name the track by what it is and
/// survive a layout change; `ordinal` is the only handle left when a
/// release ships tracks that cannot be told apart by description, and is
/// trustworthy only against the `layout` it was measured in.
nonisolated struct RememberedAudioChoice: RememberedTrackChoice {
    static let memoryNamespace = "audioTrackMemory"

    var language: String?
    var title: String?
    /// 1-based, in the engine's embedded-audio ordinal space.
    var ordinal: Int
    /// Fingerprint of the layout the ordinal was measured against. A
    /// position means nothing against a different one.
    var layout: String
    /// Reference-date seconds, used only to evict the oldest entries.
    /// Deliberately not a `Date`: the codebase keeps dates out of Codable.
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

/// How a remembered choice is matched against the item about to play, and
/// what a fresh choice should do to the stored one.
///
/// The order is the point. A track named unambiguously by its own metadata
/// is an explicit choice and outranks automatic selection. A *position*
/// speaks next, and only against a layout identical to the one the choice
/// was made in — so it never overrules a description that actually
/// identifies something, it fills the gap where description cannot.
nonisolated enum AudioTrackMemoryPolicy {
    /// Stable description of a layout's shape. Language, title and the
    /// default flag are part of it: a release that gains proper tagging is
    /// a different layout, and a position measured before it should no
    /// longer apply.
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

    /// Where the choice lands when its description names exactly one track
    /// here, or nil. Ambiguity is failure, not a coin flip: Jellyfin
    /// synthesizes a display title from codec and channel layout when a
    /// file carries none, and several tracks answering to one description
    /// identify none of them.
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
        // A title can pick up episode-specific noise ("English (SDH) -
        // Forced"), so language alone is the durable half of the match —
        // but only where it too names one track.
        guard exact.isEmpty, let language else { return nil }
        let byLanguage = streams.indices.filter { streams[$0].language == language }
        return byLanguage.count == 1 ? byLanguage[0] + 1 : nil
    }

    /// The best remaining guess once description has failed to be
    /// unambiguous: the first track of the right language. Wrong track,
    /// perhaps, but never the wrong language.
    static func approximateDescriptiveOrdinal(
        matchingLanguage language: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
    }

    /// Description alone, for the in-session carry between episodes, which
    /// has no layout fingerprint to reason about.
    static func descriptiveOrdinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        uniqueDescriptiveOrdinal(matchingLanguage: language, title: title, in: streams)
            ?? approximateDescriptiveOrdinal(matchingLanguage: language, in: streams)
    }

    /// Position, fenced by an identical layout.
    ///
    /// Reached only after description has failed to name one track, so it
    /// cannot overrule a real signal. It covers both releases that tag
    /// nothing at all and releases that tag several tracks the same way,
    /// where a position is the only thing that can express which one the
    /// viewer meant.
    static func positionalOrdinal(
        for choice: RememberedAudioChoice,
        in streams: [AudioLayoutStream]
    ) -> Int? {
        guard !streams.isEmpty,
              choice.layout == fingerprint(of: streams),
              (1...streams.count).contains(choice.ordinal) else { return nil }
        return choice.ordinal
    }

    /// The whole ladder: an unambiguous description, then position against
    /// an unchanged layout, then the right language at least.
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

    /// What a viewer's track change should do to the stored choice.
    ///
    /// Only ever decided from an actual change the viewer made. Landing
    /// back on what automatic selection would have chosen drops the
    /// override rather than storing it, or the show would be frozen against
    /// a later change of preferences. `automatic` is nil when policy named
    /// no track, and the engine starts such a layout on its first track.
    enum Outcome: Equatable {
        case remember(ordinal: Int)
        case forget
    }

    static func outcome(chosen ordinal: Int, automatic: Int?) -> Outcome {
        ordinal == (automatic ?? 1) ? .forget : .remember(ordinal: ordinal)
    }
}

/// The audio half of `TrackMemoryStore`. The namespace is what shipped, and
/// what viewers already have their choices stored under.
typealias AudioTrackMemoryStore = TrackMemoryStore<RememberedAudioChoice>
