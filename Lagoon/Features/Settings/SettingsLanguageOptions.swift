import Foundation

/// Audio and subtitle preferences offer the same platform language choices.
enum SettingsLanguageOptions {
    static var choices: [String] {
        #if os(tvOS)
        SubtitlePreferencesStore.commonLanguageChoices
        #else
        SubtitlePreferencesStore.allLanguageChoices
        #endif
    }

    #if os(tvOS)
    static func tvOptions(includeNone: Bool) -> [TVSettingsOption<String?>] {
        var options = choices.map {
            TVSettingsOption<String?>(
                value: $0,
                title: SubtitlePreferencesStore.displayName(for: $0)
            )
        }
        if includeNone {
            options.insert(TVSettingsOption(value: nil, title: String(localized: "None")), at: 0)
        }
        return options
    }
    #endif
}
