import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage(SkipMode.defaultsKey) private var skipMode: SkipMode = .autoDelay
    @AppStorage(AutoplayMode.defaultsKey) private var autoplayMode: AutoplayMode = .autoDelay
    @AppStorage(DeviceProfile.meteredOverrideKey) private var allowFullQualityOnMetered = false
    @AppStorage(MaximumQuality.defaultsKey) private var maximumQuality: MaximumQuality = .auto
    @AppStorage(GroupPlaybackDriver.correctionDefaultsKey) private var correctsSyncDrift = true

    /// Why a Watch Together picture might nudge; shared by both platforms.
    private static let syncDriftFooter = LocalizedStringKey(
        "In a Watch Together group, Lagoon nudges the speed by a fraction to bring this device back in step, and jumps when it is a long way out. Turn it off if you would rather it left the picture alone."
    )

    /// Shared by both platforms.
    private static let maximumQualityFooter = LocalizedStringKey(
        "Auto plays the original file from a server on this network. For a server elsewhere, Lagoon measures the connection first and asks for a smaller version when the original would not keep up. A fixed maximum applies everywhere."
    )

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
                footer: "These choices apply automatically whenever an intro, recap, credits, or next episode is available."
            ) {
                TVSettingsMenuPicker(
                    title: "Skip Intros, Recaps & Credits",
                    valueTitle: skipMode.shortTitle,
                    accessibilityIdentifier: "settings.playback.skipMode",
                    selection: $skipMode,
                    options: SkipMode.allCases.map {
                        TVSettingsOption(value: $0, title: String(localized: $0.title))
                    }
                )

                TVSettingsMenuPicker(
                    title: "Play Next Episode",
                    valueTitle: autoplayMode.shortTitle,
                    accessibilityIdentifier: "settings.playback.autoplayMode",
                    selection: $autoplayMode,
                    options: AutoplayMode.allCases.map {
                        TVSettingsOption(value: $0, title: String(localized: $0.title))
                    }
                )
            }

            TVSettingsSection("Quality", footer: Self.maximumQualityFooter) {
                TVSettingsMenuPicker(
                    title: "Maximum Quality",
                    valueTitle: maximumQuality.shortTitle,
                    accessibilityIdentifier: "settings.playback.maximumQuality",
                    selection: $maximumQuality,
                    options: MaximumQuality.allCases.map {
                        TVSettingsOption(value: $0, title: String(localized: $0.title))
                    }
                )
            }

            TVSettingsSection("Watch Together", footer: Self.syncDriftFooter) {
                TVSettingsToggle("Correct Sync Drift", isOn: $correctsSyncDrift)
                    .accessibilityIdentifier("settings.playback.syncDrift")
            }
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Playback") {
            Section("Playback Behavior") {
                Picker("Skip Intros, Recaps & Credits", selection: $skipMode) {
                    ForEach(SkipMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.playback.skipMode")

                Picker("Play Next Episode", selection: $autoplayMode) {
                    ForEach(AutoplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.playback.autoplayMode")
            }

            Section {
                Toggle("Correct Sync Drift", isOn: $correctsSyncDrift)
                    .accessibilityIdentifier("settings.playback.syncDrift")
            } header: {
                Text("Watch Together")
            } footer: {
                Text(Self.syncDriftFooter)
            }

            Section {
                Picker("Maximum Quality", selection: $maximumQuality) {
                    ForEach(MaximumQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .accessibilityIdentifier("settings.playback.maximumQuality")
            } header: {
                Text("Quality")
            } footer: {
                Text(Self.maximumQualityFooter)
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
}
