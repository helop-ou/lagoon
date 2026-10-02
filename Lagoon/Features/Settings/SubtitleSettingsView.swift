import SwiftUI

struct SubtitleSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Bindable var subtitlePreferences: SubtitlePreferencesStore
    @Bindable var trackPreferences: TrackPreferencesStore
    @State private var subtitleSearchAvailability: SubtitleSearchAvailability = .checking

    private enum SubtitleSearchAvailability {
        case checking, available, notEnabled, unknown
    }

    private var subtitleMode: SubtitleDefaultMode { trackPreferences.values.subtitleMode }
    private var accountID: String? { session.activeAccount?.id }

    private func refreshSubtitleSearchAvailability() async {
        subtitleSearchAvailability = .checking
        switch await session.client.refreshSubtitlePermission() {
        case true: subtitleSearchAvailability = .available
        case false: subtitleSearchAvailability = .notEnabled
        case nil: subtitleSearchAvailability = .unknown
        }
    }

    private var subtitleSearchValue: String {
        switch subtitleSearchAvailability {
        case .checking:
            return String(localized: "Checking…")
        case .available:
            let server = session.serverName ?? String(localized: "your Jellyfin server")
            return String(localized: "Available through \(server)")
        case .notEnabled:
            return String(localized: "Not enabled for this account")
        case .unknown:
            return String(localized: "Couldn't check")
        }
    }

    private var subtitleSearchFooter: LocalizedStringKey {
        switch subtitleSearchAvailability {
        case .available:
            "Your Jellyfin account may search for and download subtitles. Results come from the subtitle providers your server administrator has installed."
        case .notEnabled:
            "Ask your server administrator to turn on “Allow subtitle management” for your account. Subtitles are then found and saved by the server."
        case .unknown:
            "Lagoon couldn't reach the server to check. Subtitle search is decided by your Jellyfin account's permissions."
        case .checking:
            "Subtitle search is decided by your Jellyfin account's permissions."
        }
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
                    accessibilityIdentifier: "settings.subtitles.default",
                    selection: $trackPreferences.values.subtitleMode,
                    optionTitle: \.title
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
                    accessibilityIdentifier: "settings.subtitles.missing",
                    selection: $subtitlePreferences.values.missingMode,
                    optionTitle: \.title
                )
            }

            TVSettingsSection(
                "Subtitle Search",
                footer: subtitleSearchFooter
            ) {
                TVSettingsRowLabel("Availability", value: subtitleSearchValue)
                    .accessibilityIdentifier("settings.subtitles.search")
            }

            TVSettingsSection("Appearance") {
                NavigationLink {
                    SubtitleAppearanceSettingsView(subtitlePreferences: subtitlePreferences)
                } label: {
                    TVSettingsRowLabel("Subtitle Appearance", value: appearanceTitle, accessory: .navigation)
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
                Picker("Default", selection: $trackPreferences.values.subtitleMode) {
                    ForEach(SubtitleDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.subtitles.default")
                SettingsLanguagePickers(
                    primary: primaryLanguageBinding,
                    fallback: fallbackLanguageBinding,
                    identifierPrefix: "settings.subtitles"
                )
                Picker("When Missing", selection: $subtitlePreferences.values.missingMode) {
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
}
