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

#if !os(tvOS)
import SwiftUI

/// The touch Preferred and Fallback language pickers, shared by the audio and
/// subtitle pages. Identifiers are `<prefix>.preferred` and `<prefix>.fallback`.
struct SettingsLanguagePickers: View {
    let primary: Binding<String?>
    let fallback: Binding<String?>
    let identifierPrefix: String

    var body: some View {
        Picker("Preferred", selection: primary) {
            ForEach(SettingsLanguageOptions.choices, id: \.self) { language in
                Text(SubtitlePreferencesStore.displayName(for: language))
                    .tag(Optional(language))
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).preferred")
        Picker("Fallback", selection: fallback) {
            Text("None").tag(String?.none)
            ForEach(SettingsLanguageOptions.choices, id: \.self) { language in
                Text(SubtitlePreferencesStore.displayName(for: language))
                    .tag(Optional(language))
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).fallback")
    }
}
#endif
