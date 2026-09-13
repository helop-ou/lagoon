import SwiftUI

/// Settings › Appearance: which theme this profile wears (HEL-173).
struct AppearanceSettingsView: View {
    @Environment(SessionStore.self) private var session

    private var selection: Binding<String> {
        Binding(
            get: { ThemeStore.shared.theme.rawValue },
            set: { raw in
                guard let theme = AppTheme(rawValue: raw) else { return }
                withAnimation(.easeInOut(duration: Motion.crossfade)) {
                    ThemeStore.shared.select(theme)
                }
            }
        )
    }

    private var footer: String {
        if let name = session.userName {
            return String(localized: "Saved for \(name). Every Jellyfin user on this device keeps their own theme.")
        }
        return String(localized: "Saved for this profile. Every Jellyfin user on this device keeps their own theme.")
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
            "Appearance",
            description: "Choose the colours Lagoon wears on this profile. The brand's aqua and navy, or a softer pink for those who love it."
        ) {
            TVSettingsSection("Theme", footer: LocalizedStringKey(footer)) {
                TVSettingsMenuPicker(
                    title: "Theme",
                    valueTitle: Theme.current.title,
                    accessibilityIdentifier: "settings.appearance.theme",
                    selection: selection,
                    options: AppTheme.allCases.map {
                        TVSettingsOption(value: $0.rawValue, title: $0.title)
                    }
                )
                Text(Theme.current.settingsDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.Space.m)
                    .accessibilityIdentifier("settings.appearance.description")
            }
        }
    }
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Appearance") {
            Section {
                Picker("Theme", selection: selection) {
                    ForEach(AppTheme.allCases) { theme in
                        Label {
                            VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                                Text(theme.title)
                                Text(theme.settingsDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            ThemeSwatch(palette: theme.palette)
                        }
                        .tag(theme.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("settings.appearance.theme")
            } header: {
                Text("Theme")
            } footer: {
                Text(footer)
            }
        }
    }
    #endif
}

/// A theme's accent over its ground, as a small disc beside its name.
struct ThemeSwatch: View {
    let palette: ThemePalette

    var body: some View {
        ZStack {
            Circle().fill(palette.ground)
            Circle()
                .fill(palette.accent)
                .padding(Metrics.Space.xs)
        }
        .frame(width: Metrics.themeSwatchSize, height: Metrics.themeSwatchSize)
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
