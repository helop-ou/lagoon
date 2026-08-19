import Foundation
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
        case .system: String(localized: "Apple TV Setting")
        case .smart: String(localized: "Smart")
        case .always: String(localized: "Always")
        case .forcedOnly: String(localized: "Forced Only")
        case .off: String(localized: "Off")
        }
    }

    var settingsDescription: String {
        switch self {
        case .system:
            String(localized: "Keeps the subtitle track Jellyfin marks as default. Caption languages and appearance still follow Apple TV Settings.")
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

nonisolated struct TrackPreferenceValues: Codable, Equatable {
    var audioMode: AudioDefaultMode = .serverDefault
    var audioLanguageOverrides: [String] = []
    var subtitleMode: SubtitleDefaultMode = .system
}

/// Lagoon's per-account playback-language choices. Subtitle rendering and
/// subtitle-search preferences intentionally remain in SubtitlePreferences;
/// this store owns only the track that should be selected at playback start.
@MainActor
@Observable
final class TrackPreferencesStore {
    private(set) var accountID: String?
    var values = TrackPreferenceValues() {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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

    var preferredAudioLanguages: [String] {
        SubtitlePreferencesStore.deduplicated(
            values.audioLanguageOverrides + Locale.preferredLanguages
        )
    }

    var primaryAudioLanguage: String? {
        values.audioLanguageOverrides.first
            ?? Locale.preferredLanguages.first.flatMap(SubtitlePreferencesStore.normalizedLanguage)
    }

    var fallbackAudioLanguage: String? {
        values.audioLanguageOverrides.dropFirst().first
            ?? Locale.preferredLanguages.dropFirst().first.flatMap(SubtitlePreferencesStore.normalizedLanguage)
    }

    func setPrimaryAudioLanguage(_ language: String?) {
        var overrides = values.audioLanguageOverrides
        if !overrides.isEmpty { overrides.removeFirst() }
        if let language { overrides.insert(language, at: 0) }
        values.audioLanguageOverrides = SubtitlePreferencesStore.deduplicated(overrides)
    }

    func setFallbackAudioLanguage(_ language: String?) {
        var overrides = values.audioLanguageOverrides
        if overrides.isEmpty, let primaryAudioLanguage {
            overrides = [primaryAudioLanguage]
        }
        if overrides.count > 1 { overrides.remove(at: 1) }
        if let language { overrides.insert(language, at: min(1, overrides.count)) }
        values.audioLanguageOverrides = SubtitlePreferencesStore.deduplicated(overrides)
    }

    private func persist() {
        guard let accountID,
              let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key(accountID))
    }

    private static func key(_ accountID: String) -> String {
        "playback.trackPreferences.\(accountID)"
    }
}

/// A stream reduced to the facts that may legitimately influence automatic
/// selection. In particular there is no title: "Original" is metadata, not
/// a filename or display-name convention.
nonisolated struct TrackSelectionCandidate: Equatable {
    let language: String?
    let isDefault: Bool
    let isOriginal: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
}

nonisolated enum TrackSelectionPolicy {
    static func audioOrdinal(
        mode: AudioDefaultMode,
        candidates: [TrackSelectionCandidate],
        serverDefault: Int?,
        preferredLanguages: [String],
        originalLanguage: String?
    ) -> Int? {
        switch mode {
        case .serverDefault:
            return serverDefault
        case .preferredLanguage:
            return bestLanguage(in: candidates, preferredLanguages: preferredLanguages)
                ?? serverDefault
        case .original:
            if let original = best(in: candidates, where: { $0.isOriginal }) {
                return original
            }
            if let originalLanguage,
               let match = bestLanguage(in: candidates, preferredLanguages: [originalLanguage]) {
                return match
            }
            return bestLanguage(in: candidates, preferredLanguages: preferredLanguages)
                ?? serverDefault
        }
    }

    static func subtitleOrdinal(
        mode: SubtitleDefaultMode,
        candidates: [TrackSelectionCandidate],
        serverDefault: Int?,
        preferredLanguages: [String],
        selectedAudioLanguage: String?
    ) -> Int? {
        switch mode {
        case .system:
            return serverDefault
        case .off:
            return 0
        case .forcedOnly:
            return bestSubtitle(
                in: candidates,
                preferredLanguages: preferredLanguages,
                requireForced: true
            ) ?? rankedSubtitle(candidates.enumerated().filter { $0.element.isForced }) ?? 0
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
                ) ?? rankedSubtitle(candidates.enumerated().filter { $0.element.isForced }) ?? 0
            }
            return bestSubtitle(
                in: candidates,
                preferredLanguages: preferred,
                requireForced: false
            ) ?? serverDefault ?? 0
        }
    }

    private static func bestLanguage(
        in candidates: [TrackSelectionCandidate],
        preferredLanguages: [String]
    ) -> Int? {
        for language in SubtitlePreferencesStore.deduplicated(preferredLanguages) {
            if let match = best(in: candidates, where: {
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
        candidates.max { lhs, rhs in
            let left = (lhs.element.isForced ? 0 : 4)
                + (lhs.element.isDefault ? 2 : 0)
                + (lhs.element.isHearingImpaired ? 0 : 1)
            let right = (rhs.element.isForced ? 0 : 4)
                + (rhs.element.isDefault ? 2 : 0)
                + (rhs.element.isHearingImpaired ? 0 : 1)
            return left == right ? lhs.offset > rhs.offset : left < right
        }.map { $0.offset + 1 }
    }

    private static func best(
        in candidates: [TrackSelectionCandidate],
        where predicate: (TrackSelectionCandidate) -> Bool
    ) -> Int? {
        let matches = candidates.enumerated().filter { predicate($0.element) }
        return matches.first(where: { $0.element.isDefault }).map { $0.offset + 1 }
            ?? matches.first.map { $0.offset + 1 }
    }
}
