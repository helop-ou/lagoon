import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @Environment(\.openProfilePicker) private var openProfilePicker

    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    @State private var homePreferences = HomeSectionPreferencesStore()
    @State private var pendingAccountAction: AccountAction?

    /// Over the app when it can be, so Back returns here; otherwise the
    /// session's own picker.
    private func switchProfile() {
        if let openProfilePicker {
            openProfilePicker()
        } else {
            session.showAccountPicker()
        }
    }

    var body: some View {
        Group {
            #if os(tvOS)
            splitLayout
            #else
            touchForm
                .navigationTitle("Settings")
            #endif
        }
        .task(id: session.activeAccount?.id) {
            subtitlePreferences.configure(accountID: session.activeAccount?.id)
            #if DEBUG
            // The regression test changes this value; reset it so runs stay deterministic.
            if UserDefaults.standard.bool(forKey: "debug.settingsRegression") {
                subtitlePreferences.resetAppearanceToSystem()
            }
            #endif
            trackPreferences.configure(accountID: session.activeAccount?.id)
            homePreferences.configure(accountID: session.activeAccount?.id)
            await homePreferences.loadCatalog(client: session.client)
        }
    }

    private var audioSettings: some View {
        AudioSettingsView(trackPreferences: trackPreferences)
    }

    private var subtitleSettings: some View {
        SubtitleSettingsView(
            subtitlePreferences: subtitlePreferences,
            trackPreferences: trackPreferences
        )
    }

    /// Attach to the visible screen, never the settings root: on tvOS a
    /// dialog on the root behind a pushed page never presents.
    private func confirmingAccountActions<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content().confirmationDialog(
            "Sign Out?",
            isPresented: Binding(
                get: { pendingAccountAction == .signOut },
                set: { if !$0 { pendingAccountAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                pendingAccountAction = nil
                Task { await session.signOut() }
            }
            Button("Cancel", role: .cancel) {
                pendingAccountAction = nil
            }
        } message: {
            Text("You’ll need to sign in again to use this Jellyfin account.")
        }
    }

    // MARK: - tvOS: identity | short settings hierarchy

    #if os(tvOS)
    // Read here only for the Playback row's summary; the page owns the writes.
    @AppStorage(SkipMode.defaultsKey) private var skipMode: SkipMode = .autoDelay
    @AppStorage(AutoplayMode.defaultsKey) private var autoplayMode: AutoplayMode = .autoDelay

    private var splitLayout: some View {
        HStack(alignment: .top, spacing: Metrics.Space.section) {
            identityPanel
            settingsList
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Matches `TVSettingsPage`: the app's background, not the system grey.
        .themedPageBackground()
    }

    private var identityPanel: some View {
        VStack(spacing: Metrics.Space.l) {
            identityAvatar(size: Metrics.settingsAvatarSize)

            VStack(spacing: Metrics.Space.xs) {
                Text(session.userName ?? "—")
                    .font(.title3.bold())
                Text(session.serverName ?? "Jellyfin")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let host = session.client.serverURL?.host() {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text("Lagoon \(Changelog.runningDisplayVersion())")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, Metrics.Space.s)
        }
        .frame(width: Metrics.settingsIdentityWidth)
        .padding(.top, Metrics.Space.xxl)
    }

    private var settingsList: some View {
        ScrollView {
            VStack(spacing: Metrics.Space.m) {
                settingsDestination(
                    "Playback",
                    detail: "\(skipMode.shortTitle) · \(autoplayMode.shortTitle)",
                    id: "playback"
                ) { PlaybackSettingsView() }

                settingsDestination(
                    "Audio",
                    detail: trackPreferences.values.audioMode.title,
                    id: "audio"
                ) { audioSettings }

                settingsDestination(
                    "Subtitles",
                    detail: trackPreferences.values.subtitleMode.title,
                    id: "subtitles"
                ) { subtitleSettings }

                settingsDestination(
                    "Home Rows",
                    detail: homeRowsDetail,
                    id: "home"
                ) { HomeRowsSettingsView(preferences: homePreferences) }

                settingsDestination(
                    "Appearance",
                    detail: Theme.current.title,
                    id: "appearance"
                ) { AppearanceSettingsView() }

                settingsDestination(
                    "Seerr",
                    detail: seerr.displayName,
                    id: "seerr"
                ) { SeerrSettingsView() }

                #if DEBUG
                settingsDestination(
                    "Developer",
                    detail: "Component Previews",
                    id: "developer"
                ) {
                    DeveloperSettingsView(subtitleStyle: subtitlePreferences.renderStyle)
                }
                #endif

                settingsDestination(
                    "Advanced",
                    detail: "Playback Diagnostics",
                    id: "diagnostics"
                ) { DiagnosticsSettingsView() }

                settingsDestination(
                    "About",
                    detail: Changelog.runningDisplayVersion(),
                    id: "about"
                ) { AboutSettingsView() }

                settingsDestination(
                    "Account",
                    detail: session.userName,
                    id: "account"
                ) { accountSettings }
            }
            .padding(.vertical, Metrics.Space.l)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity)
    }

    private func settingsDestination<Destination: View>(
        _ title: LocalizedStringKey,
        detail: String? = nil,
        id: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            TVSettingsRowLabel(title, value: detail, accessory: .navigation)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("settings.category.\(id)")
    }

    private var homeRowsDetail: String {
        if homePreferences.catalog.isEmpty { return "Lagoon Native" }
        return homePreferences.values.isCustomized ? "Custom" : "Native + Plugin"
    }

    private var accountSettings: some View {
        confirmingAccountActions {
            TVSettingsPage(
                "Account",
                description: "View the active Jellyfin connection, switch between saved users, or add and remove an account."
            ) {
                TVSettingsSection("Connection") {
                    TVSettingsInfoRow("Server", value: session.serverName ?? "Jellyfin")
                    TVSettingsInfoRow("Address", value: session.client.serverURL?.host() ?? "—")
                    TVSettingsInfoRow("User", value: session.userName ?? "—")
                }

                TVSettingsSection("Account Actions") {
                    settingsAction("Switch Profile", id: "switch") { switchProfile() }
                    settingsAction("Add Profile", id: "add") { session.addAccount() }
                    settingsAction("Sign Out", id: "signOut", role: .destructive) {
                        pendingAccountAction = .signOut
                    }
                }
            }
        }
    }

    private func settingsAction(
        _ title: LocalizedStringKey,
        id: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            TVSettingsRowLabel(title)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("settings.account.\(id)")
    }

    #endif

    // MARK: - Identity avatar (both platforms)

    /// The same portrait as the picker and the profile button, so a profile
    /// looks alike everywhere.
    @ViewBuilder
    private func identityAvatar(size: CGFloat) -> some View {
        if let account = session.activeAccount {
            ProfilePortrait(account: account, size: size)
        } else {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: size, height: size)
        }
    }

    // MARK: - iOS: category list and native settings pages

    #if !os(tvOS)
    /// The tvOS categories, as native navigation and grouped Forms.
    private var touchForm: some View {
        ThemedForm {
            // The profile heads Settings, as its portrait marks the tab.
            Section {
                NavigationLink {
                    touchAccountSettings
                } label: {
                    HStack(spacing: Metrics.Space.m) {
                        identityAvatar(size: Metrics.touchAvatarSize)
                        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                            Text(session.userName ?? "Account")
                                .font(.headline)
                            Text(session.serverName ?? "Jellyfin")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityIdentifier("settings.category.account")
                Button("Switch Profile") { switchProfile() }
                    .accessibilityIdentifier("settings.root.switchProfile")
            }

            Section("Preferences") {
                touchSettingsDestination("Playback", systemImage: ContentIcon.Settings.playback, id: "playback") {
                    PlaybackSettingsView()
                }
                touchSettingsDestination("Audio", systemImage: ContentIcon.Settings.audio, id: "audio") {
                    audioSettings
                }
                touchSettingsDestination("Subtitles", systemImage: ContentIcon.Settings.subtitles, id: "subtitles") {
                    subtitleSettings
                }
                touchSettingsDestination("Home Rows", systemImage: ContentIcon.home, id: "home") {
                    HomeRowsSettingsView(preferences: homePreferences)
                }
                touchSettingsDestination("Appearance", systemImage: ContentIcon.Settings.appearance, id: "appearance") {
                    AppearanceSettingsView()
                }
            }

            Section("Services") {
                touchSettingsDestination("Seerr", systemImage: ContentIcon.discover, id: "seerr") {
                    SeerrSettingsView()
                }
            }

            Section("Application") {
                touchSettingsDestination("Advanced", systemImage: ContentIcon.Settings.advanced, id: "diagnostics") {
                    DiagnosticsSettingsView()
                }
                touchSettingsDestination("Downloads", systemImage: ContentIcon.Settings.downloads, id: "downloads") {
                    DownloadsSettingsView()
                }
                #if DEBUG
                touchSettingsDestination("Developer", systemImage: ContentIcon.Settings.developer, id: "developer") {
                    DeveloperSettingsView(subtitleStyle: subtitlePreferences.renderStyle)
                }
                #endif
                touchSettingsDestination("About", systemImage: ContentIcon.Settings.about, id: "about") {
                    AboutSettingsView()
                }
            }
        }
        .accessibilityIdentifier("settings.root")
    }

    private func touchSettingsDestination<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        id: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier("settings.category.\(id)")
    }

    private var touchAccountSettings: some View {
        TouchSettingsPage("Account") {
            Section {
                HStack(spacing: Metrics.Space.m) {
                    identityAvatar(size: Metrics.touchAvatarSize)
                    VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                        Text(session.userName ?? "—")
                            .font(.headline)
                        Text(session.serverName ?? "Jellyfin")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Section("Server") {
                LabeledContent("Server", value: session.serverName ?? "Jellyfin")
                LabeledContent("Address", value: session.client.serverURL?.absoluteString ?? "—")
                LabeledContent("User", value: session.userName ?? "—")
            }

            Section {
                Button("Switch Profile") { switchProfile() }
                    .accessibilityIdentifier("settings.account.switch")
                Button("Add Profile") { session.addAccount() }
                    .accessibilityIdentifier("settings.account.add")
                confirmingAccountActions {
                    Button("Sign Out", role: .destructive) {
                        pendingAccountAction = .signOut
                    }
                    .accessibilityIdentifier("settings.account.signOut")
                }
            }
        }
    }
    #endif
}

private enum AccountAction {
    case signOut
}
