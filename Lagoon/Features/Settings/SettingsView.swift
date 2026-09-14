import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @Environment(\.displayScale) private var displayScale

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise Atmos/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
    @AppStorage(DiagnosticsPreference.reportingEnabledKey) private var diagnosticReports = DiagnosticsPreference.defaultReportingEnabled
    @AppStorage("debug.frameLossBench") private var frameLossBench = false
    @AppStorage("debug.stripDoviEL") private var stripDoviEL = false
    /// HEL-137 lever 2, on a device that cannot be paired to Xcode: the only
    /// way to A/B libavcodec's thread count against the performance cluster
    /// is to ship the switch. Read once when the decoder opens.
    @AppStorage("debug.experimentalPlaybackCache") private var bufferTranscodes = false
    #if DEBUG
    /// One-shot, timed fault injections scheduled after playback starts.
    /// Debug-only: the exact same experiment runs in the simulator and,
    /// from a Debug build, on the paired Apple TV (HEL-123/124).
    @AppStorage("debug.simulateAudioStarvation") private var simulateAudioStarvation = false
    @AppStorage("debug.simulateDeliveryStall") private var simulateDeliveryStall = false
    /// Read once when an engine is created; off until the hardware pass
    /// sets the floor (HEL-123).
    @AppStorage("debug.bufferOnAudioStarvation") private var bufferOnAudioStarvation = false
    #endif
    @AppStorage(DeviceProfile.meteredOverrideKey) private var allowFullQualityOnMetered = false
    @AppStorage(SkipMode.defaultsKey) private var skipModeRaw = SkipMode.autoDelay.rawValue
    @AppStorage(AutoplayMode.defaultsKey) private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    @State private var homePreferences = HomeSectionPreferencesStore()
    @State private var subtitleSearchAvailability: SubtitleSearchAvailability = .checking
    @State private var pendingAccountAction: AccountAction?

    private enum SubtitleSearchAvailability {
        case checking, available, notEnabled, unknown
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
            confirmingAccountActions { splitLayout }
            #else
            touchForm
                .navigationTitle("Settings")
            #endif
        }
        .task(id: session.activeAccount?.id) {
            subtitlePreferences.configure(accountID: session.activeAccount?.id)
            #if DEBUG
            // Keep the remote-navigation regression deterministic between
            // launches. The test intentionally changes this value and tvOS
            // otherwise restores that changed state on the next run.
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
            allowFullQualityOnMetered: $allowFullQualityOnMetered
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

    /// Attach to the visible action on iOS so its native confirmation
    /// popover is anchored to Sign Out, not to the hidden settings root.
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
        // Matches `TVSettingsPage`, so the settings root and every page
        // pushed from it sit on the app's black rather than the system's
        // lifted grey.
        .background(Theme.background.ignoresSafeArea())
    }

    private var identityPanel: some View {
        VStack(spacing: Metrics.Space.l) {
            identityAvatar(size: Metrics.settingsAvatarSize, font: .largeTitle)

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
                if session.accounts.count > 1 {
                    settingsAction("Switch User", id: "switch") { session.showAccountPicker() }
                }
                settingsAction("Add Account", id: "add") { session.addAccount() }
                settingsAction("Sign Out", id: "signOut", role: .destructive) {
                    pendingAccountAction = .signOut
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

    /// The signed-in user's picture when Jellyfin has one (HEL-168);
    /// initials while it loads and for users without one, because an empty
    /// avatar frame reads worse than a letter.
    private func identityAvatar(size: CGFloat, font: Font) -> some View {
        let pixels = ArtworkSizing.pixels(for: size, displayScale: displayScale)
        // The circle fill stays under the picture so a transparent upload
        // still reads as an avatar.
        return ZStack {
            Circle().fill(.white.opacity(0.12))
            CachedAsyncImage(url: session.activeAccount?.avatarURL(maxWidth: pixels), maxPixelSize: pixels) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Text(initials)
                    .font(font.weight(.semibold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = (session.userName ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    // MARK: - iOS: category list and native settings pages

    #if !os(tvOS)
    /// Keep the same categories as tvOS, but let native navigation and
    /// grouped Forms do the work on a touch-sized screen.
    private var touchForm: some View {
        ThemedForm {
            Section {
                NavigationLink {
                    touchAccountSettings
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                            Text("Account")
                            Text([session.userName, session.serverName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: ContentIcon.Settings.account)
                    }
                }
                .accessibilityIdentifier("settings.category.account")
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
                    identityAvatar(size: Metrics.touchAvatarSize, font: .title2)
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
                if session.accounts.count > 1 {
                    Button("Switch User") { session.showAccountPicker() }
                        .accessibilityIdentifier("settings.account.switch")
                }
                Button("Add Account") { session.addAccount() }
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
    /// Marketing version with the build in brackets — "0.1 (13)".
    ///
    /// Deliberately separate from `JellyfinClient.appVersion`, which stays
    /// the marketing version alone: that one goes in the auth header and the
    /// server records it as the client version, so its format is not ours to
    /// decorate.
    ///
    /// The build is dropped when it adds nothing — absent, or identical to
    /// the marketing version, where "0.1 (0.1)" would just be noise.
    var displayVersion: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        guard let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty, build != short else {
            return short
        }
        return "\(short) (\(build))"
    }
}
