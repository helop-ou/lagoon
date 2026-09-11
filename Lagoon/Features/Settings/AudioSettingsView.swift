import SwiftUI

struct AudioSettingsView: View {
    @Binding var audioMode: AudioDefaultMode
    @Binding var primaryLanguage: String?
    @Binding var fallbackLanguage: String?

    var body: some View {
        #if os(tvOS)
        remoteSettings
        #else
        touchSettings
        #endif
    }

    #if os(tvOS)
    private var remoteSettings: some View {
        TVSettingsPage(
            "Audio",
            description: audioMode.settingsDescription
                + "\n\nLagoon applies these choices whenever an item starts."
        ) {
            TVSettingsSection(
                "Language Selection",
                footer: "Lagoon uses these preferences when each item starts. Original Audio avoids dubbed tracks when Jellyfin provides original-language metadata."
            ) {
                TVSettingsMenuPicker(
                    title: "Default Audio",
                    valueTitle: audioMode.title,
                    accessibilityIdentifier: "settings.audio.default",
                    selection: $audioMode,
                    options: AudioDefaultMode.allCases.map {
                        TVSettingsOption(value: $0, title: $0.title)
                    }
                )

                TVSettingsMenuPicker(
                    title: "Preferred Audio",
                    valueTitle: SubtitlePreferencesStore.displayName(for: primaryLanguage),
                    accessibilityIdentifier: "settings.audio.preferred",
                    selection: $primaryLanguage,
                    options: SettingsLanguageOptions.tvOptions(includeNone: false)
                )

                TVSettingsMenuPicker(
                    title: "Audio Fallback",
                    valueTitle: SubtitlePreferencesStore.displayName(for: fallbackLanguage),
                    accessibilityIdentifier: "settings.audio.fallback",
                    selection: $fallbackLanguage,
                    options: SettingsLanguageOptions.tvOptions(includeNone: true)
                )
            }
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Audio") {
            Section {
                Picker("Default", selection: $audioMode) {
                    ForEach(AudioDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.audio.default")
                Picker("Preferred", selection: $primaryLanguage) {
                    ForEach(SettingsLanguageOptions.choices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.audio.preferred")
                Picker("Fallback", selection: $fallbackLanguage) {
                    Text("None").tag(String?.none)
                    ForEach(SettingsLanguageOptions.choices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.audio.fallback")
            } header: {
                Text("Language Selection")
            } footer: {
                Text(audioMode.settingsDescription)
            }
        }
    }
    #endif
}
