import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @Environment(\.openProfilePicker) private var openProfilePicker

    // Visible in Release: TestFlight is the only way to test Atmos/HDR on hardware.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
    @AppStorage(DiagnosticsPreference.reportingEnabledKey) private var diagnosticReports = DiagnosticsPreference.defaultReportingEnabled
    @AppStorage("debug.frameLossBench") private var frameLossBench = false
    @AppStorage("debug.stripDoviEL") private var stripDoviEL = false
    @AppStorage("debug.experimentalPlaybackCache") private var bufferTranscodes = false
    #if DEBUG
    /// One-shot, timed fault injections scheduled after playback starts.
    @AppStorage("debug.simulateAudioStarvation") private var simulateAudioStarvation = false
    @AppStorage("debug.simulateDeliveryStall") private var simulateDeliveryStall = false
    /// Read once when an engine is created.
    @AppStorage("debug.bufferOnAudioStarvation") private var bufferOnAudioStarvation = false
    #endif
    @AppStorage(DeviceProfile.meteredOverrideKey) private var allowFullQualityOnMetered = false
    @AppStorage(SkipMode.defaultsKey) private var skipModeRaw = SkipMode.autoDelay.rawValue
    @AppStorage(AutoplayMode.defaultsKey) private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue
    @AppStorage(GroupPlaybackDriver.correctionDefaultsKey) private var correctsSyncDrift = true
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    @State private var homePreferences = HomeSectionPreferencesStore()
    @State private var subtitleSearchAvailability: SubtitleSearchAvailability = .checking
    @State private var pendingAccountAction: AccountAction?

    private enum SubtitleSearchAvailability {
        case checking, available, notEnabled, unknown
    }

    /// Over the app when it can be, so Back returns here; otherwise the
    /// session's own picker.
    private func switchProfile() {
        if let openProfilePicker {
            openProfilePicker()
        } else {
            session.showAccountPicker()
        }
    }

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

    private var playbackSettings: some View {
        PlaybackSettingsView(
            skipModeRaw: $skipModeRaw,
            autoplayModeRaw: $autoplayModeRaw,
            allowFullQualityOnMetered: $allowFullQualityOnMetered,
            correctsSyncDrift: $correctsSyncDrift
        )
    }

    private var audioSettings: some View {
        AudioSettingsView(
            audioMode: trackBinding(\.audioMode),
            primaryLanguage: primaryAudioLanguageBinding,
            fallbackLanguage: fallbackAudioLanguageBinding
        )
    }

    private var subtitleSettings: some View {
        SubtitleSettingsView(
            subtitlePreferences: subtitlePreferences,
            subtitleMode: trackBinding(\.subtitleMode),
            subtitleSearchValue: subtitleSearchValue,
            subtitleSearchFooter: subtitleSearchFooter,
            accountID: session.activeAccount?.id,
            refreshSubtitleSearchAvailability: refreshSubtitleSearchAvailability
        )
    }

    private var diagnosticsSettings: some View {
        #if DEBUG
        DiagnosticsSettingsView(
            showPlaybackHUD: $showPlaybackHUD,
            diagnosticReports: $diagnosticReports,
            frameLossBench: $frameLossBench,
            stripDoviEL: $stripDoviEL,
            bufferTranscodes: $bufferTranscodes,
            simulateAudioStarvation: $simulateAudioStarvation,
            simulateDeliveryStall: $simulateDeliveryStall,
            bufferOnAudioStarvation: $bufferOnAudioStarvation
        )
        #else
        DiagnosticsSettingsView(
            showPlaybackHUD: $showPlaybackHUD,
            diagnosticReports: $diagnosticReports,
            frameLossBench: $frameLossBench,
            stripDoviEL: $stripDoviEL,
            bufferTranscodes: $bufferTranscodes
        )
        #endif
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
    private var splitLayout: some View {
        HStack(alignment: .top, spacing: Metrics.Space.section) {
            identityPanel
            settingsList
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Matches `TVSettingsPage`: the app's background, not the system grey.
        .background(Theme.background.ignoresSafeArea())
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

            Text("Lagoon \(Bundle.main.displayVersion)")
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
                ) { playbackSettings }

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
                ) { diagnosticsSettings }

                settingsDestination(
                    "About",
                    detail: Bundle.main.displayVersion,
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
            TVSettingsNavigationLabel(title, detail: detail)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("settings.category.\(id)")
    }

    private var skipMode: SkipMode { SkipMode(rawValue: skipModeRaw) ?? .autoDelay }
    private var autoplayMode: AutoplayMode { AutoplayMode(rawValue: autoplayModeRaw) ?? .autoDelay }
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
                    settingsInfo("Server", value: session.serverName ?? "Jellyfin")
                    settingsInfo("Address", value: session.client.serverURL?.host() ?? "—")
                    settingsInfo("User", value: session.userName ?? "—")
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

    private func settingsInfo(_ title: LocalizedStringKey, value: String) -> some View {
        TVSettingsActionLabel(title, value: value)
            .padding(.horizontal, Metrics.Space.l)
            .frame(minHeight: 66)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func settingsAction(
        _ title: LocalizedStringKey,
        id: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            TVSettingsActionLabel(title)
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
                    playbackSettings
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
                    diagnosticsSettings
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

    private var primaryAudioLanguageBinding: Binding<String?> {
        Binding(
            get: { trackPreferences.primaryAudioLanguage },
            set: { trackPreferences.setPrimaryAudioLanguage($0) }
        )
    }

    private var fallbackAudioLanguageBinding: Binding<String?> {
        Binding(
            get: { trackPreferences.fallbackAudioLanguage },
            set: { trackPreferences.setFallbackAudioLanguage($0) }
        )
    }

    private func trackBinding<T>(
        _ keyPath: WritableKeyPath<TrackPreferenceValues, T>
    ) -> Binding<T> {
        Binding(
            get: { trackPreferences.values[keyPath: keyPath] },
            set: { newValue in
                var values = trackPreferences.values
                values[keyPath: keyPath] = newValue
                trackPreferences.values = values
            }
        )
    }
}

private enum AccountAction {
    case signOut
}

private extension Bundle {
    /// "0.1 (13)"; the build is dropped when absent or equal to the version.
    /// Not `JellyfinClient.appVersion`, which goes in the auth header as-is.
    var displayVersion: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        guard let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty, build != short else {
            return short
        }
        return "\(short) (\(build))"
    }
}
