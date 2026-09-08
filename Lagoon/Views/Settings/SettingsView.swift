import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise Atmos/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
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
    @AppStorage("playback.skipMode") private var skipModeRaw = SkipMode.autoDelay.rawValue
    @AppStorage("playback.autoplayMode") private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue
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
        .background(Color.black.ignoresSafeArea())
    }

    private var identityPanel: some View {
        VStack(spacing: Metrics.Space.l) {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                Text(initials)
                    .font(.largeTitle.weight(.semibold))
            }
            .frame(width: Metrics.settingsAvatarSize, height: Metrics.settingsAvatarSize)

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

    private var playbackSettings: some View {
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

    private var audioSettings: some View {
        TVSettingsPage(
            "Audio",
            description: trackPreferences.values.audioMode.settingsDescription
                + "\n\nLagoon applies these choices whenever an item starts."
        ) {
            TVSettingsSection(
                "Language Selection",
                footer: "Lagoon uses these preferences when each item starts. Original Audio avoids dubbed tracks when Jellyfin provides original-language metadata."
            ) {
                TVSettingsMenuPicker(
                    title: "Default Audio",
                    valueTitle: trackPreferences.values.audioMode.title,
                    accessibilityIdentifier: "settings.audio.default",
                    selection: trackBinding(\.audioMode),
                    options: AudioDefaultMode.allCases.map {
                        TVSettingsOption(value: $0, title: $0.title)
                    }
                )

                TVSettingsMenuPicker(
                    title: "Preferred Audio",
                    valueTitle: SubtitlePreferencesStore.displayName(for: trackPreferences.primaryAudioLanguage),
                    accessibilityIdentifier: "settings.audio.preferred",
                    selection: primaryAudioLanguageBinding,
                    options: languageOptions(includeNone: false)
                )

                TVSettingsMenuPicker(
                    title: "Audio Fallback",
                    valueTitle: SubtitlePreferencesStore.displayName(for: trackPreferences.fallbackAudioLanguage),
                    accessibilityIdentifier: "settings.audio.fallback",
                    selection: fallbackAudioLanguageBinding,
                    options: languageOptions(includeNone: true)
                )
            }
        }
    }

    private var subtitleSettings: some View {
        TVSettingsPage(
            "Subtitles",
            description: trackPreferences.values.subtitleMode.settingsDescription
                + "\n\nPreferred and fallback languages are also used when Lagoon searches for a missing subtitle."
        ) {
            TVSettingsSection(
                "Language Selection",
                footer: "These defaults are applied when playback starts and when Lagoon searches for a missing subtitle."
            ) {
                TVSettingsMenuPicker(
                    title: "Default Subtitles",
                    valueTitle: trackPreferences.values.subtitleMode.title,
                    accessibilityIdentifier: "settings.subtitles.default",
                    selection: trackBinding(\.subtitleMode),
                    options: SubtitleDefaultMode.allCases.map {
                        TVSettingsOption(value: $0, title: $0.title)
                    }
                )

                TVSettingsMenuPicker(
                    title: "Preferred Subtitle",
                    valueTitle: SubtitlePreferencesStore.displayName(for: subtitlePreferences.primaryLanguage),
                    accessibilityIdentifier: "settings.subtitles.preferred",
                    selection: primaryLanguageBinding,
                    options: languageOptions(includeNone: false)
                )

                TVSettingsMenuPicker(
                    title: "Subtitle Fallback",
                    valueTitle: SubtitlePreferencesStore.displayName(for: subtitlePreferences.fallbackLanguage),
                    accessibilityIdentifier: "settings.subtitles.fallback",
                    selection: fallbackLanguageBinding,
                    options: languageOptions(includeNone: true)
                )

                TVSettingsMenuPicker(
                    title: "When Subtitles Are Missing",
                    valueTitle: subtitlePreferences.values.missingMode.title,
                    accessibilityIdentifier: "settings.subtitles.missing",
                    selection: subtitleBinding(\.missingMode),
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
                    subtitleAppearanceSettings
                } label: {
                    TVSettingsNavigationLabel("Subtitle Appearance", detail: appearanceTitle)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.subtitles.appearance")
            }
        }
        .task(id: session.activeAccount?.id) {
            await refreshSubtitleSearchAvailability()
        }
    }

    private var subtitleAppearanceSettings: some View {
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
                settingsToggle(
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

    private var diagnosticsSettings: some View {
        TVSettingsPage(
            "Advanced",
            description: "Tools for diagnosing playback compatibility. Leave them off during normal viewing."
        ) {
            TVSettingsSection(
                "Playback Diagnostics",
                footer: "These options can affect playback behavior and are intended for troubleshooting."
            ) {
                settingsToggle("Show Playback Details", isOn: $showPlaybackHUD)
                    .accessibilityIdentifier("settings.diagnostics.hud")
                settingsToggle("Run Playback Performance Test", isOn: $frameLossBench)
                    .accessibilityIdentifier("settings.diagnostics.frameLoss")
                settingsToggle("Dolby Vision Compatibility Mode", isOn: $stripDoviEL)
                    .accessibilityIdentifier("settings.diagnostics.dovi")
                settingsToggle("Buffer Transcoded Playback", isOn: $bufferTranscodes)
                    .accessibilityIdentifier("settings.diagnostics.transcodeCache")
                #if DEBUG
                settingsToggle("Simulate Audio Starvation", isOn: $simulateAudioStarvation)
                    .accessibilityIdentifier("settings.diagnostics.audioStarvation")
                settingsToggle("Simulate Delivery Stall", isOn: $simulateDeliveryStall)
                    .accessibilityIdentifier("settings.diagnostics.deliveryStall")
                settingsToggle("Buffer on Audio Starvation", isOn: $bufferOnAudioStarvation)
                    .accessibilityIdentifier("settings.diagnostics.audioBuffering")
                #endif
            }

            #if os(tvOS)
            let status = TopShelfStore.status()
            TVSettingsSection(
                "Top Shelf",
                // The result carries an underlying error where there is one,
                // and a row truncates to a single line — which is how "could
                // not write to the shared container" reached us without the
                // reason attached to it. A footer wraps.
                footer: """
                Last result: \(status.lastResult ?? "not run yet").

                What Lagoon has handed to the Apple TV Home screen. The shelf itself only appears when Lagoon is in the top row. If titles are published here but the shelf stays on the Lagoon banner, the problem is the shelf rather than the app.
                """
            ) {
                TVSettingsActionLabel(
                    "Shared Container",
                    value: status.containerAvailable ? "Available" : "Unavailable"
                )
                TVSettingsActionLabel("Titles Published", value: "\(status.publishedCount)")
                TVSettingsActionLabel("Artwork Files", value: "\(status.artworkCount)")
                TVSettingsActionLabel(
                    "Last Published",
                    value: status.lastPublished.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "Never"
                )
                TVSettingsActionLabel(
                    "Last Attempt",
                    value: status.lastAttempt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "Never"
                )
            }
            #endif
        }
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

    private func settingsToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.Space.l)
        .frame(minHeight: 66)
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

    private func languageOptions(includeNone: Bool) -> [TVSettingsOption<String?>] {
        var options = settingsLanguageChoices.map {
            TVSettingsOption<String?>(
                value: $0,
                title: SubtitlePreferencesStore.displayName(for: $0)
            )
        }
        if includeNone {
            options.insert(TVSettingsOption(value: nil, title: String(localized: "None")), at: 0)
        }
        return options
    }

    /// Initials rather than a photo: Jellyfin user images are optional and
    /// usually absent, and an empty avatar frame reads worse than a letter.
    private var initials: String {
        let parts = (session.userName ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
    #endif

    // MARK: - iOS: category list and native settings pages

    #if !os(tvOS)
    /// Keep the same categories as tvOS, but let native navigation and
    /// grouped Forms do the work on a touch-sized screen.
    private var touchForm: some View {
        Form {
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
                    touchPlaybackSettings
                }
                touchSettingsDestination("Audio", systemImage: ContentIcon.Settings.audio, id: "audio") {
                    touchAudioSettings
                }
                touchSettingsDestination("Subtitles", systemImage: ContentIcon.Settings.subtitles, id: "subtitles") {
                    touchSubtitleSettings
                }
                touchSettingsDestination("Home Rows", systemImage: ContentIcon.home, id: "home") {
                    HomeRowsSettingsView(preferences: homePreferences)
                }
            }

            Section("Services") {
                touchSettingsDestination("Seerr", systemImage: ContentIcon.discover, id: "seerr") {
                    SeerrSettingsView()
                }
            }

            Section("Application") {
                touchSettingsDestination("Advanced", systemImage: ContentIcon.Settings.advanced, id: "diagnostics") {
                    touchDiagnosticsSettings
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
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
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

    private func touchSettingsPage<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form(content: content)
            .pickerStyle(.navigationLink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
    }

    private var touchAccountSettings: some View {
        touchSettingsPage("Account") {
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

    private var touchPlaybackSettings: some View {
        touchSettingsPage("Playback") {
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

    private var touchAudioSettings: some View {
        touchSettingsPage("Audio") {
            Section {
                Picker("Default", selection: trackBinding(\.audioMode)) {
                    ForEach(AudioDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.audio.default")
                Picker("Preferred", selection: primaryAudioLanguageBinding) {
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.audio.preferred")
                Picker("Fallback", selection: fallbackAudioLanguageBinding) {
                    Text("None").tag(String?.none)
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.audio.fallback")
            } header: {
                Text("Language Selection")
            } footer: {
                Text(trackPreferences.values.audioMode.settingsDescription)
            }
        }
    }

    private var touchSubtitleSettings: some View {
        touchSettingsPage("Subtitles") {
            Section("Subtitle Languages") {
                Picker("Default", selection: trackBinding(\.subtitleMode)) {
                    ForEach(SubtitleDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.subtitles.default")
                Picker("Preferred", selection: primaryLanguageBinding) {
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.subtitles.preferred")
                Picker("Fallback", selection: fallbackLanguageBinding) {
                    Text("None").tag(String?.none)
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .accessibilityIdentifier("settings.subtitles.fallback")
                Picker("When Missing", selection: subtitleBinding(\.missingMode)) {
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
                    touchSubtitleAppearanceSettings
                } label: {
                    LabeledContent("Subtitle Appearance", value: appearanceTitle)
                }
                .accessibilityIdentifier("settings.subtitles.appearance")
            }
        }
        .task(id: session.activeAccount?.id) {
            await refreshSubtitleSearchAvailability()
        }
    }

    private var touchSubtitleAppearanceSettings: some View {
        touchSettingsPage("Subtitle Appearance") {
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

    private var touchDiagnosticsSettings: some View {
        touchSettingsPage("Advanced") {
            Section {
                Toggle("Show Playback Details", isOn: $showPlaybackHUD)
                    .accessibilityIdentifier("settings.diagnostics.hud")
                Toggle("Run Playback Performance Test", isOn: $frameLossBench)
                    .accessibilityIdentifier("settings.diagnostics.frameLoss")
                Toggle("Dolby Vision Compatibility Mode", isOn: $stripDoviEL)
                    .accessibilityIdentifier("settings.diagnostics.dovi")
                #if DEBUG
                Toggle("Simulate Audio Starvation", isOn: $simulateAudioStarvation)
                    .accessibilityIdentifier("settings.diagnostics.audioStarvation")
                Toggle("Simulate Delivery Stall", isOn: $simulateDeliveryStall)
                    .accessibilityIdentifier("settings.diagnostics.deliveryStall")
                Toggle("Buffer on Audio Starvation", isOn: $bufferOnAudioStarvation)
                    .accessibilityIdentifier("settings.diagnostics.audioBuffering")
                #endif
            } header: {
                Text("Playback Diagnostics")
            } footer: {
                Text("These options can affect playback behavior and are intended for troubleshooting. Leave them off during normal viewing.")
            }
        }
    }
    #endif

    private var appearanceTitle: String {
        subtitlePreferences.values.followsSystemAppearance
            ? String(localized: "System")
            : String(localized: "Lagoon")
    }

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

    private var settingsLanguageChoices: [String] {
        #if os(tvOS)
        SubtitlePreferencesStore.commonLanguageChoices
        #else
        SubtitlePreferencesStore.allLanguageChoices
        #endif
    }

    private var primaryLanguageBinding: Binding<String?> {
        Binding(
            get: { subtitlePreferences.primaryLanguage },
            set: { subtitlePreferences.setPrimaryLanguage($0) }
        )
    }

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

    private var fallbackLanguageBinding: Binding<String?> {
        Binding(
            get: { subtitlePreferences.fallbackLanguage },
            set: { subtitlePreferences.setFallbackLanguage($0) }
        )
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
