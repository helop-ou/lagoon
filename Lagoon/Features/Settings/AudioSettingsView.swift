import SwiftUI

struct AudioSettingsView: View {
    @Bindable var trackPreferences: TrackPreferencesStore

    private var audioMode: AudioDefaultMode { trackPreferences.values.audioMode }

    private var primaryLanguage: Binding<String?> {
        Binding(
            get: { trackPreferences.primaryAudioLanguage },
            set: { trackPreferences.setPrimaryAudioLanguage($0) }
        )
    }

    private var fallbackLanguage: Binding<String?> {
        Binding(
            get: { trackPreferences.fallbackAudioLanguage },
            set: { trackPreferences.setFallbackAudioLanguage($0) }
        )
    }

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
                    accessibilityIdentifier: "settings.audio.default",
                    selection: $trackPreferences.values.audioMode,
                    optionTitle: \.title
                )

                TVSettingsMenuPicker(
                    title: "Preferred Audio",
                    valueTitle: SubtitlePreferencesStore.displayName(for: trackPreferences.primaryAudioLanguage),
                    accessibilityIdentifier: "settings.audio.preferred",
                    selection: primaryLanguage,
                    options: SettingsLanguageOptions.tvOptions(includeNone: false)
                )

                TVSettingsMenuPicker(
                    title: "Audio Fallback",
                    valueTitle: SubtitlePreferencesStore.displayName(for: trackPreferences.fallbackAudioLanguage),
                    accessibilityIdentifier: "settings.audio.fallback",
                    selection: fallbackLanguage,
                    options: SettingsLanguageOptions.tvOptions(includeNone: true)
                )
            }
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Audio") {
            Section {
                Picker("Default", selection: $trackPreferences.values.audioMode) {
                    ForEach(AudioDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.audio.default")
                SettingsLanguagePickers(
                    primary: primaryLanguage,
                    fallback: fallbackLanguage,
                    identifierPrefix: "settings.audio"
                )
            } header: {
                Text("Language Selection")
            } footer: {
                Text(audioMode.settingsDescription)
            }
        }
    }
    #endif
}
