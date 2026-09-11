import SwiftUI

struct PlaybackSettingsView: View {
    @Binding var skipModeRaw: String
    @Binding var autoplayModeRaw: String
    @Binding var allowFullQualityOnMetered: Bool

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
            "Playback",
            description: "Choose how Lagoon handles skippable segments and episode endings. Display matching is always requested during playback; Apple TV's Video and Audio settings decide whether the television changes mode."
        ) {
            TVSettingsSection(
                "Playback Behavior",
                footer: "These choices apply automatically whenever an intro, recap, or next episode is available."
            ) {
                TVSettingsMenuPicker(
                    title: "Skip Intros & Recaps",
                    valueTitle: skipMode.shortTitle,
                    accessibilityIdentifier: "settings.playback.skipMode",
                    selection: $skipModeRaw,
                    options: SkipMode.allCases.map {
                        TVSettingsOption(value: $0.rawValue, title: String(localized: $0.title))
                    }
                )

                TVSettingsMenuPicker(
                    title: "Play Next Episode",
                    valueTitle: autoplayMode.shortTitle,
                    accessibilityIdentifier: "settings.playback.autoplayMode",
                    selection: $autoplayModeRaw,
                    options: AutoplayMode.allCases.map {
                        TVSettingsOption(value: $0.rawValue, title: String(localized: $0.title))
                    }
                )
            }
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Playback") {
            Section("Playback Behavior") {
                Picker("Skip Intros & Recaps", selection: $skipModeRaw) {
                    ForEach(SkipMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.playback.skipMode")

                Picker("Play Next Episode", selection: $autoplayModeRaw) {
                    ForEach(AutoplayMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.playback.autoplayMode")
            }

            Section {
                Toggle("Full Quality on Cellular", isOn: $allowFullQualityOnMetered)
                    .accessibilityIdentifier("settings.playback.fullQualityOnMetered")
            } header: {
                Text("Cellular")
            } footer: {
                Text("""
                On cellular or a personal hotspot Lagoon asks your server for a \
                smaller version of a film rather than the full file, which can be \
                tens of gigabytes. Turn this on if the connection is one you know \
                is fast and unmetered.
                """)
            }
        }
    }
    #endif

    private var skipMode: SkipMode { SkipMode(rawValue: skipModeRaw) ?? .autoDelay }
    private var autoplayMode: AutoplayMode { AutoplayMode(rawValue: autoplayModeRaw) ?? .autoDelay }
}
