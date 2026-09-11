import SwiftUI

struct SubtitleSettingsView: View {
    let subtitlePreferences: SubtitlePreferencesStore
    @Binding var subtitleMode: SubtitleDefaultMode
    let subtitleSearchValue: String
    let subtitleSearchFooter: LocalizedStringKey
    let accountID: String?
    let refreshSubtitleSearchAvailability: () async -> Void

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
            "Subtitles",
            description: subtitleMode.settingsDescription
                + "\n\nPreferred and fallback languages are also used when Lagoon searches for a missing subtitle."
        ) {
            TVSettingsSection(
                "Language Selection",
                footer: "These defaults are applied when playback starts and when Lagoon searches for a missing subtitle."
            ) {
                TVSettingsMenuPicker(
                    title: "Default Subtitles",
                    valueTitle: subtitleMode.title,
                    accessibilityIdentifier: "settings.subtitles.default",
                    selection: $subtitleMode,
                    options: SubtitleDefaultMode.allCases.map {
                        TVSettingsOption(value: $0, title: $0.title)
                    }
                )

                TVSettingsMenuPicker(
                    title: "Preferred Subtitle",
                    valueTitle: SubtitlePreferencesStore.displayName(for: subtitlePreferences.primaryLanguage),
                    accessibilityIdentifier: "settings.subtitles.preferred",
                    selection: primaryLanguageBinding,
                    options: SettingsLanguageOptions.tvOptions(includeNone: false)
                )

                TVSettingsMenuPicker(
                    title: "Subtitle Fallback",
                    valueTitle: SubtitlePreferencesStore.displayName(for: subtitlePreferences.fallbackLanguage),
                    accessibilityIdentifier: "settings.subtitles.fallback",
                    selection: fallbackLanguageBinding,
                    options: SettingsLanguageOptions.tvOptions(includeNone: true)
                )

                TVSettingsMenuPicker(
                    title: "When Subtitles Are Missing",
                    valueTitle: subtitlePreferences.values.missingMode.title,
                    accessibilityIdentifier: "settings.subtitles.missing",
                    selection: missingModeBinding,
                    options: MissingSubtitleMode.allCases.map {
                        TVSettingsOption(value: $0, title: $0.title)
                    }
                )
            }

            TVSettingsSection(
                "Subtitle Search",
                footer: subtitleSearchFooter
            ) {
                TVSettingsActionLabel("Availability", value: subtitleSearchValue)
                    .accessibilityIdentifier("settings.subtitles.search")
            }

            TVSettingsSection("Appearance") {
                NavigationLink {
                    SubtitleAppearanceSettingsView(subtitlePreferences: subtitlePreferences)
                } label: {
                    TVSettingsNavigationLabel("Subtitle Appearance", detail: appearanceTitle)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.subtitles.appearance")
            }
        }
        .task(id: accountID) {
            await refreshSubtitleSearchAvailability()
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Subtitles") {
            Section("Subtitle Languages") {
                Picker("Default", selection: $subtitleMode) {
                    ForEach(SubtitleDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.subtitles.default")
                Picker("Preferred", selection: primaryLanguageBinding) {
                    ForEach(SettingsLanguageOptions.choices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.subtitles.preferred")
                Picker("Fallback", selection: fallbackLanguageBinding) {
                    Text("None").tag(String?.none)
                    ForEach(SettingsLanguageOptions.choices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.subtitles.fallback")
                Picker("When Missing", selection: missingModeBinding) {
                    ForEach(MissingSubtitleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.subtitles.missing")
            }

            Section {
                LabeledContent("Availability", value: subtitleSearchValue)
                    .accessibilityIdentifier("settings.subtitles.search")
            } header: {
                Text("Subtitle Search")
            } footer: {
                Text(subtitleSearchFooter)
            }

            Section("Appearance") {
                NavigationLink {
                    SubtitleAppearanceSettingsView(subtitlePreferences: subtitlePreferences)
                } label: {
                    LabeledContent("Subtitle Appearance", value: appearanceTitle)
                }
                .accessibilityIdentifier("settings.subtitles.appearance")
            }
        }
        .task(id: accountID) {
            await refreshSubtitleSearchAvailability()
        }
    }
    #endif

    private var appearanceTitle: String {
        subtitlePreferences.values.followsSystemAppearance
            ? String(localized: "System")
            : String(localized: "Lagoon")
    }

    private var primaryLanguageBinding: Binding<String?> {
        Binding(
            get: { subtitlePreferences.primaryLanguage },
            set: { subtitlePreferences.setPrimaryLanguage($0) }
        )
    }

    private var fallbackLanguageBinding: Binding<String?> {
        Binding(
            get: { subtitlePreferences.fallbackLanguage },
            set: { subtitlePreferences.setFallbackLanguage($0) }
        )
    }

    private var missingModeBinding: Binding<MissingSubtitleMode> {
        Binding(
            get: { subtitlePreferences.values.missingMode },
            set: { newValue in
                var values = subtitlePreferences.values
                values.missingMode = newValue
                subtitlePreferences.values = values
            }
        )
    }
}
