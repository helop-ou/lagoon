import Foundation
import LagoonEngine

/// One subtitle stream reduced to what identifies it again in a sibling
/// episode. The flags describe the layout's shape: forced, hearing-impaired
/// and external are what separate tracks sharing a language.
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

/// A subtitle choice the viewer made, kept across player presentations.
/// Unlike audio, "no subtitles" is an answer, and the one a server default
/// is most likely to overrule, so it is remembered too.
nonisolated struct RememberedSubtitleChoice: RememberedTrackChoice {
    static let memoryNamespace = "subtitleTrackMemory"

    var isOff: Bool
    var language: String?
    var title: String?
    /// 1-based, in the engine's subtitle ordinal space: embedded tracks first,
    /// then external ones, with 0 meaning no subtitles.
    var ordinal: Int
    /// Fingerprint of the layout the ordinal was measured against.
    var layout: String
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

/// How a remembered subtitle choice matches the item about to play. The same
/// ladder as `AudioTrackMemoryPolicy`, kept separate because the two differ
/// in what makes a layout's shape and in off being an answer here.
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

    /// The ordinal when the description names exactly one track, else nil. A
    /// release with "English" three times (full, forced, SDH) names none of them
    /// by language alone.
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

    /// Last resort: the first track of the right language. Maybe forced instead
    /// of full, but never a language the viewer cannot read.
    static func approximateDescriptiveOrdinal(
        matchingLanguage language: String?,
        in streams: [SubtitleLayoutStream]
    ) -> Int? {
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
    }

    /// Position, fenced by an identical layout. Reached only after description
    /// fails.
    static func positionalOrdinal(
        for choice: RememberedSubtitleChoice,
        in streams: [SubtitleLayoutStream]
    ) -> Int? {
        guard !streams.isEmpty,
              choice.layout == fingerprint(of: streams),
              (1...streams.count).contains(choice.ordinal) else { return nil }
        return choice.ordinal
    }

    /// The whole ladder. Off answers immediately: it names no track and holds
    /// across layout changes.
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

    /// What a viewer's subtitle change does to the stored choice. `automatic` is
    /// nil where the engine starts with subtitles off, so turning them off there
    /// is no override, while turning off a server default is.
    enum Outcome: Equatable {
        case remember(ordinal: Int)
        case forget
    }

    static func outcome(chosen ordinal: Int, automatic: Int?) -> Outcome {
        ordinal == (automatic ?? offOrdinal) ? .forget : .remember(ordinal: ordinal)
    }
}

typealias SubtitleTrackMemoryStore = TrackMemoryStore<RememberedSubtitleChoice>
