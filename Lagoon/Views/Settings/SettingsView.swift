import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise Atmos/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
    @AppStorage("debug.frameLossBench") private var frameLossBench = false
    @AppStorage("debug.stripDoviEL") private var stripDoviEL = false
    @AppStorage("debug.matchContent") private var matchContent = true
    @AppStorage("playback.skipMode") private var skipModeRaw = SkipMode.autoDelay.rawValue
    @AppStorage("playback.autoplayMode") private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    @State private var homePreferences = HomeSectionPreferencesStore()

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
            trackPreferences.configure(accountID: session.activeAccount?.id)
            homePreferences.configure(accountID: session.activeAccount?.id)
            await homePreferences.loadCatalog(client: session.client)
        }
    }

    // MARK: - tvOS: identity | settings list

    #if os(tvOS)
    /// Who you are on the left, one scrolling list of settings on the right
    /// — the Infuse shape (Jaagop's reference, 2026-08-18).
    ///
    /// The left half is *identity, not navigation*. An earlier attempt put a
    /// section list there; splitting five short sections across two panes
    /// only moved the emptiness around, because none of them has enough in
    /// it to fill a pane. The settings are few enough to live in one list,
    /// so the left side earns its place by answering "which server and user
    /// am I looking at" instead.
    private var splitLayout: some View {
        HStack(alignment: .top, spacing: Metrics.Space.section) {
            identityPanel
            settingsList
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var identityPanel: some View {
        VStack(spacing: Metrics.Space.l) {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                Text(initials)
                    .font(.system(size: 72, weight: .semibold))
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
                // Rows carry their current value on the right and cycle it
                // on Select, so the list stays one row per setting rather
                // than one row per option.
                row("Skip Intros & Recaps", value: skipMode.shortTitle) {
                    cycleSkipMode()
                }
                row("Play Next Episode", value: autoplayMode.shortTitle) {
                    cycleAutoplayMode()
                }
                if !homePreferences.catalog.isEmpty {
                    NavigationLink {
                        HomeRowsSettingsView(preferences: homePreferences)
                    } label: {
                        HStack(spacing: Metrics.Space.xl) {
                            Text("Home Rows")
                            Spacer(minLength: Metrics.Space.xl)
                            Text(homePreferences.values.isConfigured ? "Custom" : "Lagoon Default")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                row("Default Audio", value: trackPreferences.values.audioMode.title) {
                    cycleTrackValue(\.audioMode)
                }
                row("Preferred Audio", value: SubtitlePreferencesStore.displayName(for: trackPreferences.primaryAudioLanguage)) {
                    cycleAudioLanguage(primary: true)
                }
                row("Audio Fallback", value: SubtitlePreferencesStore.displayName(for: trackPreferences.fallbackAudioLanguage)) {
                    cycleAudioLanguage(primary: false)
                }
                row("Default Subtitles", value: trackPreferences.values.subtitleMode.title) {
                    cycleTrackValue(\.subtitleMode)
                }
                row("Subtitle Appearance", value: appearanceTitle) {
                    var values = subtitlePreferences.values
                    values.followsSystemAppearance.toggle()
                    subtitlePreferences.values = values
                }
                row("Subtitle Size", value: subtitlePreferences.values.textSize.title) {
                    cycleSubtitleValue(\.textSize)
                }
                row("Subtitle Edge", value: subtitlePreferences.values.edgeStyle.title) {
                    cycleSubtitleValue(\.edgeStyle)
                }
                row("Subtitle Background", value: subtitlePreferences.values.background.title) {
                    cycleSubtitleValue(\.background)
                }
                row("Subtitle Position", value: subtitlePreferences.values.verticalPosition.title) {
                    cycleSubtitleValue(\.verticalPosition)
                }
                row("Preferred Subtitle", value: SubtitlePreferencesStore.displayName(for: subtitlePreferences.primaryLanguage)) {
                    cycleLanguage(primary: true)
                }
                row("Subtitle Fallback", value: SubtitlePreferencesStore.displayName(for: subtitlePreferences.fallbackLanguage)) {
                    cycleLanguage(primary: false)
                }
                row("When Subtitles Are Missing", value: subtitlePreferences.values.missingMode.title) {
                    cycleMissingSubtitleMode()
                }
                subtitlePreview
                row("Playback HUD", value: showPlaybackHUD ? "On" : "Off") {
                    showPlaybackHUD.toggle()
                }
                // Both HEL-64 diagnostics: the bench freezes a controlled
                // frame-loss number into the HUD, the strip is the DoVi P7
                // enhancement-layer A/B for real hardware.
                row("Frame-Loss Bench", value: frameLossBench ? "On" : "Off") {
                    frameLossBench.toggle()
                }
                row("Strip DoVi Enhancement Layer", value: stripDoviEL ? "On" : "Off") {
                    stripDoviEL.toggle()
                }
                // On by default: matching frame rate + dynamic range is
                // correct player behavior, and the system's own Match
                // Content settings gate it anyway. Off here holds an A/B
                // still (HEL-64).
                row("Match Content Display Mode", value: matchContent ? "On" : "Off") {
                    matchContent.toggle()
                }

                // Only worth offering once there is somewhere to switch to;
                // with one account it is a button that shows you yourself.
                if session.accounts.count > 1 {
                    row("Switch User") { session.showAccountPicker() }
                }
                row("Add Account") { session.addAccount() }
                // Signing out forgets this account, because logout revokes
                // the token server-side and a remembered dead session is
                // worse than none. Other accounts survive (HEL-38).
                row("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
            }
            // Headroom for the focus lift lives inside the scroller, same
            // rule as every other focusable scroll area.
            .padding(.vertical, Metrics.Space.l)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity)
    }

    private func row(
        _ title: LocalizedStringKey,
        value: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: Metrics.Space.xl) {
                Text(title)
                Spacer(minLength: Metrics.Space.xl)
                if let value {
                    // No explicit colour: the focused lozenge owns its label
                    // colours, and `.secondary` resolves against whichever
                    // side of that it lands on.
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
    }

    private var skipMode: SkipMode { SkipMode(rawValue: skipModeRaw) ?? .autoDelay }
    private var autoplayMode: AutoplayMode { AutoplayMode(rawValue: autoplayModeRaw) ?? .autoDelay }

    private func cycleSkipMode() {
        let all = SkipMode.allCases
        let next = (all.firstIndex(of: skipMode).map { $0 + 1 } ?? 0) % all.count
        skipModeRaw = all[next].rawValue
    }

    private func cycleAutoplayMode() {
        let all = AutoplayMode.allCases
        let next = (all.firstIndex(of: autoplayMode).map { $0 + 1 } ?? 0) % all.count
        autoplayModeRaw = all[next].rawValue
    }

    /// Initials rather than a photo: Jellyfin user images are optional and
    /// usually absent, and an empty avatar frame reads worse than a letter.
    private var initials: String {
        let parts = (session.userName ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
    #endif

    // MARK: - Touch

    #if !os(tvOS)
    /// `Form` is right on iOS: there is no focused lozenge to fight, and the
    /// identity split would be wrong for the width.
    private var touchForm: some View {
        Form {
            Section("Server") {
                LabeledContent("Server", value: session.serverName ?? "Jellyfin")
                LabeledContent("Address", value: session.client.serverURL?.absoluteString ?? "—")
                LabeledContent("User", value: session.userName ?? "—")
            }

            Section {
                if session.accounts.count > 1 {
                    Button("Switch User") { session.showAccountPicker() }
                }
                Button("Add Account") { session.addAccount() }
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
            }

            Section("Skip Intros & Recaps") {
                Picker("When one starts", selection: $skipModeRaw) {
                    ForEach(SkipMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }

            Section("Play Next Episode") {
                Picker("When one ends", selection: $autoplayModeRaw) {
                    ForEach(AutoplayMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }

            if !homePreferences.catalog.isEmpty {
                Section("Home") {
                    NavigationLink("Home Rows") {
                        HomeRowsSettingsView(preferences: homePreferences)
                    }
                }
            }

            Section("Audio Languages") {
                Picker("Default", selection: trackBinding(\.audioMode)) {
                    ForEach(AudioDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Preferred", selection: primaryAudioLanguageBinding) {
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                Picker("Fallback", selection: fallbackAudioLanguageBinding) {
                    Text("None").tag(String?.none)
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
            }

            Section("Subtitle Languages") {
                Picker("Default", selection: trackBinding(\.subtitleMode)) {
                    ForEach(SubtitleDefaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Preferred", selection: primaryLanguageBinding) {
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                Picker("Fallback", selection: fallbackLanguageBinding) {
                    Text("None").tag(String?.none)
                    ForEach(settingsLanguageChoices, id: \.self) { language in
                        Text(SubtitlePreferencesStore.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                Picker("When Missing", selection: subtitleBinding(\.missingMode)) {
                    ForEach(MissingSubtitleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Subtitle Appearance") {
                Toggle("Use System Caption Style", isOn: subtitleBinding(\.followsSystemAppearance))
                Picker("Size", selection: subtitleBinding(\.textSize, customAppearance: true)) {
                    ForEach(SubtitleTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("Edge", selection: subtitleBinding(\.edgeStyle, customAppearance: true)) {
                    ForEach(SubtitleEdgeStyle.allCases) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
                Picker("Background", selection: subtitleBinding(\.background, customAppearance: true)) {
                    ForEach(SubtitleBackground.allCases) { background in
                        Text(background.title).tag(background)
                    }
                }
                Picker("Position", selection: subtitleBinding(\.verticalPosition, customAppearance: true)) {
                    ForEach(SubtitleVerticalPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                subtitlePreview
                Button("Reset to System") {
                    subtitlePreferences.resetAppearanceToSystem()
                }
            }

            Section("About") {
                LabeledContent("App", value: "Lagoon")
                LabeledContent("Version", value: Bundle.main.displayVersion)
            }

            Section("Debug") {
                Toggle("Playback HUD", isOn: $showPlaybackHUD)
                Toggle("Frame-Loss Bench", isOn: $frameLossBench)
                Toggle("Strip DoVi Enhancement Layer", isOn: $stripDoviEL)
                Toggle("Match Content Display Mode", isOn: $matchContent)
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
        return Text("Subtitle preview")
            .font(style.font)
            .foregroundStyle(style.foregroundColor)
            .subtitleEdge(style.edgeStyle, color: style.edgeColor)
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
            .background(
                style.backgroundColor.opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("settings.subtitlePreview")
    }

    private func cycleSubtitleValue<T>(
        _ keyPath: WritableKeyPath<SubtitlePreferenceValues, T>
    ) where T: CaseIterable & Equatable {
        let all = Array(T.allCases)
        guard !all.isEmpty else { return }
        var values = subtitlePreferences.values
        let current = values[keyPath: keyPath]
        let next = (all.firstIndex(of: current).map { $0 + 1 } ?? 0) % all.count
        values[keyPath: keyPath] = all[next]
        values.followsSystemAppearance = false
        subtitlePreferences.values = values
    }

    private func cycleMissingSubtitleMode() {
        let all = MissingSubtitleMode.allCases
        var values = subtitlePreferences.values
        let next = (all.firstIndex(of: values.missingMode).map { $0 + 1 } ?? 0) % all.count
        values.missingMode = all[next]
        subtitlePreferences.values = values
    }

    private func cycleTrackValue<T>(
        _ keyPath: WritableKeyPath<TrackPreferenceValues, T>
    ) where T: CaseIterable & Equatable {
        let all = Array(T.allCases)
        guard !all.isEmpty else { return }
        var values = trackPreferences.values
        let current = values[keyPath: keyPath]
        let next = (all.firstIndex(of: current).map { $0 + 1 } ?? 0) % all.count
        values[keyPath: keyPath] = all[next]
        trackPreferences.values = values
    }

    private func cycleAudioLanguage(primary: Bool) {
        var options = settingsLanguageChoices.map(Optional.some)
        if !primary { options.insert(nil, at: 0) }
        let current = primary
            ? trackPreferences.primaryAudioLanguage
            : trackPreferences.fallbackAudioLanguage
        let next = (options.firstIndex(where: { $0 == current }).map { $0 + 1 } ?? 0) % options.count
        if primary {
            trackPreferences.setPrimaryAudioLanguage(options[next])
        } else {
            trackPreferences.setFallbackAudioLanguage(options[next])
        }
    }

    private func cycleLanguage(primary: Bool) {
        var options = settingsLanguageChoices.map(Optional.some)
        if !primary { options.insert(nil, at: 0) }
        let current = primary ? subtitlePreferences.primaryLanguage : subtitlePreferences.fallbackLanguage
        let next = (options.firstIndex(where: { $0 == current }).map { $0 + 1 } ?? 0) % options.count
        if primary {
            subtitlePreferences.setPrimaryLanguage(options[next])
        } else {
            subtitlePreferences.setFallbackLanguage(options[next])
        }
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
