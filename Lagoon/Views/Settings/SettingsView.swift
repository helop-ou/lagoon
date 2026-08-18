import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise Atmos/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
    @AppStorage("debug.frameLossBench") private var frameLossBench = false
    @AppStorage("debug.stripDoviEL") private var stripDoviEL = false
    @AppStorage("playback.skipMode") private var skipModeRaw = SkipMode.autoDelay.rawValue
    @AppStorage("playback.autoplayMode") private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue

    var body: some View {
        #if os(tvOS)
        splitLayout
        #else
        touchForm
            .navigationTitle("Settings")
        #endif
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

            Section("About") {
                LabeledContent("App", value: "Lagoon")
                LabeledContent("Version", value: Bundle.main.displayVersion)
            }

            Section("Debug") {
                Toggle("Playback HUD", isOn: $showPlaybackHUD)
                Toggle("Frame-Loss Bench", isOn: $frameLossBench)
                Toggle("Strip DoVi Enhancement Layer", isOn: $stripDoviEL)
            }
        }
    }
    #endif
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
