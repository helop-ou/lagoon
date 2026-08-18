import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise Atmos/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
    @AppStorage("playback.skipMode") private var skipMode = SkipMode.autoDelay.rawValue

    #if os(tvOS)
    /// Sections down the left, their contents on the right — the tvOS
    /// settings shape. One tall column left most of a 16:9 screen empty and
    /// pushed later sections off the bottom edge.
    private enum Pane: String, CaseIterable, Identifiable {
        case server, account, playback, about, debug

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .server: "Server"
            case .account: "Account"
            case .playback: "Playback"
            case .about: "About"
            case .debug: "Debug"
            }
        }
    }

    @State private var selected: Pane = .server
    @FocusState private var focusedPane: Pane?
    #endif

    var body: some View {
        #if os(tvOS)
        splitLayout
        #else
        touchForm
            .navigationTitle("Settings")
        #endif
    }

    // MARK: - tvOS: sections | content

    #if os(tvOS)
    private var splitLayout: some View {
        HStack(alignment: .top, spacing: Metrics.Space.section) {
            sidebar
            detailPane
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Selection follows focus — the same grammar the player panel's tab
        // bar uses. Walking the list previews each section instead of making
        // every look cost a Select and a Menu to get back out.
        .onChange(of: focusedPane) { _, pane in
            guard let pane else { return }
            withAnimation(.easeInOut(duration: Motion.fast)) { selected = pane }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            ForEach(Pane.allCases) { pane in
                Button {
                    // Focus already selected it; Select is just a way in.
                    selected = pane
                } label: {
                    Text(pane.title)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
                .focused($focusedPane, equals: pane)
            }
        }
        .frame(width: Metrics.settingsSidebarWidth, alignment: .leading)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                detail(for: selected)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Headroom for the focus lift lives inside the scroller, same
            // rule as every other focusable scroll area.
            .padding(.vertical, Metrics.Space.l)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .server:
            infoRow("Server", session.serverName ?? "Jellyfin")
            infoRow("Address", session.client.serverURL?.absoluteString ?? "—")
            infoRow("User", session.userName ?? "—")

        case .account:
            // Only worth offering once there is somewhere to switch to; with
            // one account it is a button that shows you yourself.
            if session.accounts.count > 1 {
                Button("Switch User") { session.showAccountPicker() }
                    .buttonStyle(.glass)
            }
            Button("Add Account") { session.addAccount() }
                .buttonStyle(.glass)
            // Signing out forgets this account, because logout revokes the
            // token server-side and a remembered dead session is worse than
            // none. Other accounts are untouched (HEL-38).
            Button("Sign Out", role: .destructive) {
                Task { await session.signOut() }
            }
            .buttonStyle(.glass)

        case .playback:
            // Intro and recap only. Credits hand off to the next episode
            // rather than being jumped, and Preview/Commercial turn up
            // mid-film in real libraries (HEL-63).
            header("Skip Intros & Recaps")
            ForEach(SkipMode.allCases) { mode in
                Button {
                    skipMode = mode.rawValue
                } label: {
                    Label {
                        Text(mode.title)
                    } icon: {
                        // Selection through content, never a tint — the rule
                        // the whole HEL-50/HEL-62 family comes from.
                        Image(systemName: skipMode == mode.rawValue ? "checkmark.circle.fill" : "circle")
                    }
                }
                .buttonStyle(.glass)
            }

        case .about:
            infoRow("App", "Lagoon")
            infoRow("Version", session.client.appVersion)

        case .debug:
            Button {
                showPlaybackHUD.toggle()
            } label: {
                Label(
                    "Playback HUD",
                    systemImage: showPlaybackHUD ? "checkmark.circle.fill" : "circle"
                )
            }
            .buttonStyle(.glass)
        }
    }

    /// Label left, value right. Deliberately *not* a `Button`: read-only rows
    /// that take focus give the remote somewhere pointless to go, and the
    /// focused lozenge would imply an action that doesn't exist.
    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: Metrics.Space.xl)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.vertical, Metrics.Space.s)
    }

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, Metrics.Space.xs)
    }
    #endif

    // MARK: - Touch

    #if !os(tvOS)
    /// `Form` is right on iOS: there is no focused lozenge to fight, and a
    /// two-pane split would be wrong for the width.
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
                Picker("When one starts", selection: $skipMode) {
                    ForEach(SkipMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }

            Section("About") {
                LabeledContent("App", value: "Lagoon")
                LabeledContent("Version", value: session.client.appVersion)
            }

            Section("Debug") {
                Toggle("Playback HUD", isOn: $showPlaybackHUD)
            }
        }
    }
    #endif
}
