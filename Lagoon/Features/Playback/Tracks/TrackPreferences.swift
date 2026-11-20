import Foundation
import LagoonEngine
import Observation

nonisolated enum AudioDefaultMode: String, Codable, CaseIterable, Identifiable {
    case serverDefault
    case original
    case preferredLanguage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .serverDefault: String(localized: "Jellyfin Default")
        case .original: String(localized: "Original Audio")
        case .preferredLanguage: String(localized: "Preferred Language")
        }
    }

    var settingsDescription: String {
        switch self {
        case .serverDefault:
            String(localized: "Uses the audio track Jellyfin marks as default.")
        case .original:
            String(localized: "Prefers the title's original-language audio and falls back to your preferred languages when that metadata is unavailable.")
        case .preferredLanguage:
            String(localized: "Selects your preferred audio language first, then your fallback language, and finally Jellyfin's default.")
        }
    }
}

nonisolated enum SubtitleDefaultMode: String, Codable, CaseIterable, Identifiable {
    case system
    case smart
    case always
    case forcedOnly
    case off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System Setting")
        case .smart: String(localized: "Smart")
        case .always: String(localized: "Always")
        case .forcedOnly: String(localized: "Forced Only")
        case .off: String(localized: "Off")
        }
    }

    var settingsDescription: String {
        switch self {
        case .system:
            String(localized: "Keeps the subtitle track Jellyfin marks as default. Caption languages and appearance still follow system settings.")
        case .smart:
            String(localized: "Shows full subtitles when the audio is not in one of your preferred languages. When the audio is preferred, only forced subtitles are selected.")
        case .always:
            String(localized: "Selects a full subtitle track in your preferred or fallback language whenever one is available.")
        case .forcedOnly:
            String(localized: "Selects only forced subtitles, such as translations for foreign-language dialogue.")
        case .off:
            String(localized: "Starts playback with subtitles turned off.")
        }
    }
}

/// The most channels audio is played with: wider tracks are downmixed.
nonisolated enum AudioChannelLimit: String, Codable, CaseIterable, Identifiable {
    case off
    case surround
    case stereo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .surround: String(localized: "5.1")
        case .stereo: String(localized: "Stereo")
        }
    }

    var engineLimit: AudioShaping.ChannelLimit? {
        switch self {
        case .off: nil
        case .surround: .surround
        case .stereo: .stereo
        }
    }

    /// What the player's audio options show for the engine's limit.
    init(engineLimit: AudioShaping.ChannelLimit?) {
        switch engineLimit {
        case nil: self = .off
        case .surround: self = .surround
        case .stereo: self = .stereo
        }
    }
}

nonisolated struct TrackPreferenceValues: Codable, Equatable {
    var audioMode: AudioDefaultMode = .serverDefault
    var audioLanguageOverrides: [String] = []
    var subtitleMode: SubtitleDefaultMode = .system
    /// Set from the player: they suit a moment (late at night, a mumbled
    /// film), and the next title keeps them.
    var nightMode = false
    var dialogueBoost = false
    /// Set in Settings: it suits the room or the speakers.
    var channelLimit = AudioChannelLimit.off

    var audioShaping: AudioShaping {
        AudioShaping(nightMode: nightMode, dialogueBoost: dialogueBoost, channelLimit: channelLimit.engineLimit)
    }

    init(
        audioMode: AudioDefaultMode = .serverDefault,
        audioLanguageOverrides: [String] = [],
        subtitleMode: SubtitleDefaultMode = .system,
        nightMode: Bool = false,
        dialogueBoost: Bool = false,
        channelLimit: AudioChannelLimit = .off
    ) {
        self.audioMode = audioMode
        self.audioLanguageOverrides = audioLanguageOverrides
        self.subtitleMode = subtitleMode
        self.nightMode = nightMode
        self.dialogueBoost = dialogueBoost
        self.channelLimit = channelLimit
    }

    /// Every key optional, so preferences saved before a field existed keep
    /// the rest instead of resetting.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioMode = try container.decodeIfPresent(AudioDefaultMode.self, forKey: .audioMode) ?? .serverDefault
        audioLanguageOverrides = try container.decodeIfPresent([String].self, forKey: .audioLanguageOverrides) ?? []
        subtitleMode = try container.decodeIfPresent(SubtitleDefaultMode.self, forKey: .subtitleMode) ?? .system
        nightMode = try container.decodeIfPresent(Bool.self, forKey: .nightMode) ?? false
        dialogueBoost = try container.decodeIfPresent(Bool.self, forKey: .dialogueBoost) ?? false
        channelLimit = (try? container.decodeIfPresent(AudioChannelLimit.self, forKey: .channelLimit)) ?? .off
    }
}

/// Per-account playback-language choices: which track to select at start.
/// Subtitle rendering and search preferences live in SubtitlePreferences.
@MainActor
@Observable
final class TrackPreferencesStore {
    private(set) var accountID: String?
    var values = TrackPreferenceValues() {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func configure(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        guard let accountID,
              let data = defaults.data(forKey: Self.key(accountID)),
              let decoded = try? JSONDecoder().decode(TrackPreferenceValues.self, from: data) else {
            values = TrackPreferenceValues()
            return
        }
        values = decoded
    }

    private var audioLanguageOrder: LanguagePreferenceOrder {
        LanguagePreferenceOrder(
            overrides: values.audioLanguageOverrides,
            system: Locale.preferredLanguages
        )
    }

    var preferredAudioLanguages: [String] {
        audioLanguageOrder.preferred
    }

    var primaryAudioLanguage: String? {
        audioLanguageOrder.primary
    }

    var fallbackAudioLanguage: String? {
        audioLanguageOrder.fallback
    }

    func setPrimaryAudioLanguage(_ language: String?) {
        values.audioLanguageOverrides = audioLanguageOrder.settingPrimary(language)
    }

    func setFallbackAudioLanguage(_ language: String?) {
        values.audioLanguageOverrides = audioLanguageOrder.settingFallback(language)
    }

    private func persist() {
        guard let accountID,
              let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key(accountID))
    }

    /// The defaults key before the account id. `AccountLocalData` lists it,
    /// so the record goes when the account does.
    nonisolated static let keyPrefix = "playback.trackPreferences."

    private static func key(_ accountID: String) -> String {
        keyPrefix + accountID
    }
}

/// The device's caption setting, which `SubtitleDefaultMode.system` follows.
/// The caller reads it from MediaAccessibility, so the policy stays pure.
nonisolated enum SystemCaptionDisplay {
    case forcedOnly
    case automatic
    case alwaysOn
    /// A display type this build does not know. Jellyfin's default stands.
    case unrecognized
}

/// A stream reduced to the facts that may influence automatic selection.
/// "Original" is metadata, not a naming convention. Titles are read only for
/// signs and songs, commentary and audio description, which carry no flag.
nonisolated struct TrackSelectionCandidate: Equatable {
    let language: String?
    let isDefault: Bool
    let isOriginal: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    /// Titled "Signs & Songs", "S&S", "Forced" and the like. Counts as forced
    /// only through `resolvingTitledForced`.
    var isTitledForced = false
    /// Read from the title: Jellyfin passes no flag for either.
    var isCommentary = false
    var isAudioDescription = false
}

nonisolated enum TrackSelectionPolicy {
    /// Anime releases often ship a signs-and-songs track without the forced
    /// flag. Whole words only, so "Signs" inside another word never counts,
    /// and never a title that says the track is more than that: "English
    /// (Songs & Signs included)" and "Non-Forced" are full dialogue.
    static func titleNamesForcedTrack(_ title: String?) -> Bool {
        guard let title else { return false }
        let lowered = title.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: fullDialogueWords.contains) { return false }
        if words.contains(where: { ["signs", "songs", "forced"].contains($0) }) {
            return true
        }
        return lowered.split { !$0.isLetter && !$0.isNumber && $0 != "&" }.contains("s&s")
    }

    static func titleNamesCommentary(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0 == "commentary" || $0 == "commentaries" }
    }

    /// "AD" counts only in capitals and as a whole word.
    static func titleNamesAudioDescription(_ title: String?) -> Bool {
        guard let title else { return false }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("AD") {
            return true
        }
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        let phrase = " " + words.joined(separator: " ") + " "
        return audioDescriptionPhrases.contains { phrase.contains(" \($0) ") }
    }

    private static let audioDescriptionPhrases = [
        "audio description", "audio described", "audiodescription",
        "described video", "descriptive audio", "descriptive video",
        "video description", "visually impaired", "dvs",
    ]

    /// Words that mark a titled track as the full dialogue, whatever else
    /// its title names.
    private static let fullDialogueWords: Set<Substring> = [
        "full", "dialogue", "dialog", "complete", "non", "not", "no",
        "incl", "include", "included", "includes", "including", "plus", "sdh", "cc",
    ]

    /// Marks a titled signs-and-songs track as forced where the flag is
    /// missing. Only where no track of its language is flagged forced, so a
    /// real flag always wins, and only beside a track of that language not
    /// titled that way: a lone track, or a release name repeated on every
    /// track (a film called "Signs"), never changes what an ordinary movie
    /// or show selects.
    static func resolvingTitledForced(
        _ candidates: [TrackSelectionCandidate]
    ) -> [TrackSelectionCandidate] {
        func language(_ candidate: TrackSelectionCandidate) -> String? {
            candidate.language.flatMap(SubtitlePreferencesStore.normalizedLanguage)
        }
        let byLanguage = Dictionary(grouping: candidates, by: language)
        return candidates.map { candidate in
            guard candidate.isTitledForced, !candidate.isForced,
                  let siblings = byLanguage[language(candidate)],
                  !siblings.contains(where: \.isForced),
                  siblings.contains(where: { !$0.isTitledForced }) else { return candidate }
            return TrackSelectionCandidate(
                language: candidate.language,
                isDefault: candidate.isDefault,
                isOriginal: candidate.isOriginal,
                isForced: true,
                isHearingImpaired: candidate.isHearingImpaired,
                isTitledForced: true,
                isCommentary: candidate.isCommentary,
                isAudioDescription: candidate.isAudioDescription
            )
        }
    }

    /// The mode picks a language, then the best track in it: the main one,
    /// or the described one when the system's Audio Descriptions setting asks
    /// for it. That holds for Jellyfin's default too, which can name a
    /// commentary.
    static func audioOrdinal(
        mode: AudioDefaultMode,
        candidates: [TrackSelectionCandidate],
        serverDefault: Int?,
        preferredLanguages: [String],
        originalLanguage: String?,
        prefersAudioDescriptions: Bool
    ) -> Int? {
        let ranking = AudioRanking(prefersDescriptions: prefersAudioDescriptions)
        let chosen: Int?
        switch mode {
        case .serverDefault:
            chosen = serverDefault
        case .preferredLanguage:
            chosen = bestLanguage(in: candidates, preferredLanguages: preferredLanguages, ranking: ranking)
                ?? serverDefault
        case .original:
            if let original = best(in: candidates, ranking: ranking, where: { $0.isOriginal }) {
                chosen = original
            } else if let originalLanguage,
                      let match = bestLanguage(
                          in: candidates,
                          preferredLanguages: [originalLanguage],
                          ranking: ranking
                      ) {
                chosen = match
            } else {
                chosen = bestLanguage(in: candidates, preferredLanguages: preferredLanguages, ranking: ranking)
                    ?? serverDefault
            }
        }
        return chosen.map { bestInLanguage(of: $0, in: candidates, ranking: ranking) }
    }

    /// Main audio above a described track, and commentary last. A viewer who
    /// asks for audio descriptions gets the described track first.
    private struct AudioRanking {
        let prefersDescriptions: Bool

        func rank(_ candidate: TrackSelectionCandidate) -> Int {
            if candidate.isCommentary { return 0 }
            if candidate.isAudioDescription { return prefersDescriptions ? 3 : 1 }
            return 2
        }
    }

    /// The best track in the chosen one's language, or the chosen one when
    /// none ranks higher.
    private static func bestInLanguage(
        of ordinal: Int,
        in candidates: [TrackSelectionCandidate],
        ranking: AudioRanking
    ) -> Int {
        guard candidates.indices.contains(ordinal - 1) else { return ordinal }
        let chosen = candidates[ordinal - 1]
        let language = chosen.language.flatMap(SubtitlePreferencesStore.normalizedLanguage)
        guard let best = best(in: candidates, ranking: ranking, where: {
            $0.language.flatMap(SubtitlePreferencesStore.normalizedLanguage) == language
        }), ranking.rank(candidates[best - 1]) > ranking.rank(chosen) else { return ordinal }
        return best
    }

    static func subtitleOrdinal(
        mode: SubtitleDefaultMode,
        candidates: [TrackSelectionCandidate],
        serverDefault: Int?,
        preferredLanguages: [String],
        selectedAudioLanguage: String?,
        captionDisplay: SystemCaptionDisplay
    ) -> Int? {
        let flagged = candidates
        let candidates = resolvingTitledForced(candidates)
        // Any forced track at all, one Jellyfin flagged before a titled one.
        let anyForced = rankedSubtitle(flagged.enumerated().filter { $0.element.isForced })
            ?? rankedSubtitle(candidates.enumerated().filter { $0.element.isForced })
        switch mode {
        case .system:
            return systemSubtitle(
                display: captionDisplay,
                candidates: candidates,
                serverDefault: serverDefault,
                preferredLanguages: preferredLanguages,
                selectedAudioLanguage: selectedAudioLanguage
            )
        case .off:
            return 0
        case .forcedOnly:
            return bestSubtitle(
                in: candidates,
                preferredLanguages: preferredLanguages,
                requireForced: true
            ) ?? anyForced ?? 0
        case .always:
            return bestSubtitle(
                in: candidates,
                preferredLanguages: preferredLanguages,
                requireForced: false
            ) ?? serverDefault ?? rankedSubtitle(Array(candidates.enumerated())) ?? 0
        case .smart:
            let preferred = SubtitlePreferencesStore.deduplicated(preferredLanguages)
            let audio = selectedAudioLanguage.flatMap(SubtitlePreferencesStore.normalizedLanguage)
            if let audio, preferred.contains(audio) {
                return bestSubtitle(
                    in: candidates,
                    preferredLanguages: preferred,
                    requireForced: true
                ) ?? anyForced ?? 0
            }
            return bestSubtitle(
                in: candidates,
                preferredLanguages: preferred,
                requireForced: false
            ) ?? serverDefault ?? 0
        }
    }

    /// Follows the device's caption setting. Jellyfin's default wins when
    /// present, except under Forced Only. Unlike the other modes, a
    /// hearing-impaired track is preferred within a language.
    private static func systemSubtitle(
        display: SystemCaptionDisplay,
        candidates: [TrackSelectionCandidate],
        serverDefault: Int?,
        preferredLanguages: [String],
        selectedAudioLanguage: String?
    ) -> Int? {
        let preferred = SubtitlePreferencesStore.deduplicated(preferredLanguages)

        typealias Track = (offset: Int, element: TrackSelectionCandidate)

        func first(in tracks: [Track]) -> Int? {
            (tracks.first(where: { $0.element.isHearingImpaired }) ?? tracks.first)
                .map { $0.offset + 1 }
        }

        // Full dialogue: a forced or signs-titled track only when nothing
        // else in that language fits. Language comes first, so a titled
        // track in the viewer's language beats any track in another.
        func pick(in tracks: [Track], requireForced: Bool) -> Int? {
            let tiers: [(Track) -> Bool] = requireForced
                ? [{ $0.element.isForced }]
                : [
                    { !$0.element.isForced && !$0.element.isTitledForced },
                    { !$0.element.isForced },
                    { _ in true },
                ]
            for language in preferred {
                let matching = tracks.filter {
                    $0.element.language.flatMap(SubtitlePreferencesStore.normalizedLanguage) == language
                }
                for tier in tiers {
                    if let match = first(in: matching.filter(tier)) { return match }
                }
            }
            for tier in tiers {
                if let match = first(in: tracks.filter(tier)) { return match }
            }
            return nil
        }

        func best(requireForced: Bool) -> Int? {
            pick(in: Array(candidates.enumerated()), requireForced: requireForced)
        }

        switch display {
        case .forcedOnly:
            return best(requireForced: true) ?? 0
        case .alwaysOn:
            return serverDefault ?? best(requireForced: false) ?? 0
        case .automatic:
            if let serverDefault { return serverDefault }
            if let forced = best(requireForced: true) { return forced }
            let audio = selectedAudioLanguage.flatMap(SubtitlePreferencesStore.normalizedLanguage)
            if let primary = preferred.first, let audio, audio != primary {
                return best(requireForced: false)
            }
            return 0
        case .unrecognized:
            return serverDefault
        }
    }

    private static func bestLanguage(
        in candidates: [TrackSelectionCandidate],
        preferredLanguages: [String],
        ranking: AudioRanking
    ) -> Int? {
        for language in SubtitlePreferencesStore.deduplicated(preferredLanguages) {
            if let match = best(in: candidates, ranking: ranking, where: {
                $0.language.flatMap(SubtitlePreferencesStore.normalizedLanguage) == language
            }) {
                return match
            }
        }
        return nil
    }

    private static func bestSubtitle(
        in candidates: [TrackSelectionCandidate],
        preferredLanguages: [String],
        requireForced: Bool
    ) -> Int? {
        let allowed = candidates.enumerated().filter { _, candidate in
            !requireForced || candidate.isForced
        }
        for language in SubtitlePreferencesStore.deduplicated(preferredLanguages) {
            let matching = allowed.filter {
                $0.element.language.flatMap(SubtitlePreferencesStore.normalizedLanguage) == language
            }
            if let best = rankedSubtitle(matching) { return best }
        }
        return nil
    }

    private static func rankedSubtitle(
        _ candidates: [(offset: Int, element: TrackSelectionCandidate)]
    ) -> Int? {
        // A titled signs track left unresolved, beside a flagged forced one,
        // is still no full-dialogue track.
        func score(_ candidate: TrackSelectionCandidate) -> Int {
            (candidate.isForced ? 0 : 8)
                + (candidate.isTitledForced && !candidate.isForced ? 0 : 4)
                + (candidate.isDefault ? 2 : 0)
                + (candidate.isHearingImpaired ? 0 : 1)
        }
        return candidates.max { lhs, rhs in
            let left = score(lhs.element)
            let right = score(rhs.element)
            return left == right ? lhs.offset > rhs.offset : left < right
        }.map { $0.offset + 1 }
    }

    /// The highest-ranked match, then the default, then the first.
    private static func best(
        in candidates: [TrackSelectionCandidate],
        ranking: AudioRanking,
        where predicate: (TrackSelectionCandidate) -> Bool
    ) -> Int? {
        let filtered = candidates.enumerated().filter { predicate($0.element) }
        guard let top = filtered.map({ ranking.rank($0.element) }).max() else { return nil }
        let matches = filtered.filter { ranking.rank($0.element) == top }
        return matches.first(where: { $0.element.isDefault }).map { $0.offset + 1 }
            ?? matches.first.map { $0.offset + 1 }
    }
}
