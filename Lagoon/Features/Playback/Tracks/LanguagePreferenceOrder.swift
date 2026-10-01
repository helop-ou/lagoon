import Foundation

/// A viewer's language order for one kind of track: the languages they chose
/// in Lagoon, then the system's. Audio and subtitles each keep their own
/// overrides and read a different system list, but order them the same way.
nonisolated struct LanguagePreferenceOrder {
    /// What the viewer chose in Lagoon, in order. Wins over the system.
    let overrides: [String]
    /// What the system prefers. May be raw identifiers; they are normalized
    /// where they are read.
    let system: [String]

    /// Overrides first, then the system, each language once.
    var preferred: [String] {
        SubtitlePreferencesStore.deduplicated(overrides + system)
    }

    var primary: String? {
        overrides.first ?? system.first.flatMap(SubtitlePreferencesStore.normalizedLanguage)
    }

    var fallback: String? {
        overrides.dropFirst().first
            ?? system.dropFirst().first.flatMap(SubtitlePreferencesStore.normalizedLanguage)
    }

    /// The overrides after replacing the primary, or clearing it with nil. The
    /// fallback keeps its place.
    func settingPrimary(_ language: String?) -> [String] {
        var updated = overrides
        if !updated.isEmpty { updated.removeFirst() }
        if let language { updated.insert(language, at: 0) }
        return SubtitlePreferencesStore.deduplicated(updated)
    }

    /// The overrides after replacing the fallback, or clearing it with nil.
    /// With no overrides yet, the system's primary is pinned first, so the
    /// fallback does not slide into the primary slot.
    func settingFallback(_ language: String?) -> [String] {
        var updated = overrides
        if updated.isEmpty, let primary {
            updated = [primary]
        }
        if updated.count > 1 { updated.remove(at: 1) }
        if let language { updated.insert(language, at: min(1, updated.count)) }
        return SubtitlePreferencesStore.deduplicated(updated)
    }
}
