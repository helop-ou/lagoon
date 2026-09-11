import SwiftUI

struct SubtitleAppearanceSettingsView: View {
    let subtitlePreferences: SubtitlePreferencesStore

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
            "Subtitle Appearance",
            backTitle: "Subtitles",
            description: "Use the caption style configured in Apple TV Settings, or turn it off here to customize Lagoon's text subtitles. Authored bitmap subtitles keep their original appearance."
        ) {
            TVSettingsSection("Preview") {
                subtitlePreview
            }

            TVSettingsSection(
                "Style",
                footer: "System style follows the caption appearance selected in Apple TV Settings. Changing a Lagoon style option switches to a custom style."
            ) {
                TVSettingsToggle(
                    "Use System Caption Style",
                    isOn: subtitleBinding(\.followsSystemAppearance)
                )
                .accessibilityIdentifier("settings.subtitles.systemAppearance")

                if !subtitlePreferences.values.followsSystemAppearance {
                    TVSettingsMenuPicker(
                        title: "Size",
                        valueTitle: subtitlePreferences.values.textSize.title,
                        accessibilityIdentifier: "settings.subtitles.size",
                        selection: subtitleBinding(\.textSize, customAppearance: true),
                        options: SubtitleTextSize.allCases.map {
                            TVSettingsOption(value: $0, title: $0.title)
                        }
                    )

                    TVSettingsMenuPicker(
                        title: "Edge",
                        valueTitle: subtitlePreferences.values.edgeStyle.title,
                        accessibilityIdentifier: "settings.subtitles.edge",
                        selection: subtitleBinding(\.edgeStyle, customAppearance: true),
                        options: SubtitleEdgeStyle.allCases.map {
                            TVSettingsOption(value: $0, title: $0.title)
                        }
                    )

                    TVSettingsMenuPicker(
                        title: "Background",
                        valueTitle: subtitlePreferences.values.background.title,
                        accessibilityIdentifier: "settings.subtitles.background",
                        selection: subtitleBinding(\.background, customAppearance: true),
                        options: SubtitleBackground.allCases.map {
                            TVSettingsOption(value: $0, title: $0.title)
                        }
                    )

                    TVSettingsMenuPicker(
                        title: "Position",
                        valueTitle: subtitlePreferences.values.verticalPosition.title,
                        accessibilityIdentifier: "settings.subtitles.position",
                        selection: subtitleBinding(\.verticalPosition, customAppearance: true),
                        options: SubtitleVerticalPosition.allCases.map {
                            TVSettingsOption(value: $0, title: $0.title)
                        }
                    )
                }
            }
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Subtitle Appearance") {
            Section("Preview") {
                subtitlePreview
            }

            Section("Style") {
                Toggle("Use System Caption Style", isOn: subtitleBinding(\.followsSystemAppearance))
                    .accessibilityIdentifier("settings.subtitles.systemAppearance")
                if !subtitlePreferences.values.followsSystemAppearance {
                    Picker("Size", selection: subtitleBinding(\.textSize, customAppearance: true)) {
                        ForEach(SubtitleTextSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .accessibilityIdentifier("settings.subtitles.size")
                    Picker("Edge", selection: subtitleBinding(\.edgeStyle, customAppearance: true)) {
                        ForEach(SubtitleEdgeStyle.allCases) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }
                    .accessibilityIdentifier("settings.subtitles.edge")
                    Picker("Background", selection: subtitleBinding(\.background, customAppearance: true)) {
                        ForEach(SubtitleBackground.allCases) { background in
                            Text(background.title).tag(background)
                        }
                    }
                    .accessibilityIdentifier("settings.subtitles.background")
                    Picker("Position", selection: subtitleBinding(\.verticalPosition, customAppearance: true)) {
                        ForEach(SubtitleVerticalPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .accessibilityIdentifier("settings.subtitles.position")
                } else {
                    Text("Appearance follows Accessibility → Subtitles & Captioning in Settings. Turn off system style to customize captions in Lagoon.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Reset to System") {
                    subtitlePreferences.resetAppearanceToSystem()
                }
                .accessibilityIdentifier("settings.subtitles.reset")
            }
        }
    }
    #endif

    private var subtitlePreview: some View {
        let style = subtitlePreferences.renderStyle
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [.indigo.opacity(0.45), .black.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("This is how subtitles will look.")
                .font(style.font)
                .foregroundStyle(style.foregroundColor)
                .subtitleEdge(style.edgeStyle, color: style.edgeColor)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.vertical, Metrics.Space.s)
                .background(
                    style.backgroundColor.opacity(style.backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .padding(.bottom, Metrics.Space.l)
        }
            .frame(maxWidth: .infinity, minHeight: 150)
            .accessibilityIdentifier("settings.subtitlePreview")
    }

    private func subtitleBinding<T>(
        _ keyPath: WritableKeyPath<SubtitlePreferenceValues, T>,
        customAppearance: Bool = false
    ) -> Binding<T> {
        Binding(
            get: { subtitlePreferences.values[keyPath: keyPath] },
            set: { newValue in
                var values = subtitlePreferences.values
                values[keyPath: keyPath] = newValue
                if customAppearance {
                    values.followsSystemAppearance = false
                }
                subtitlePreferences.values = values
            }
        )
    }
}
