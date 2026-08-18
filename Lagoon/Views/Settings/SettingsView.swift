import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise Atmos/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Server", value: session.serverName ?? "Jellyfin")
                LabeledContent("Address", value: session.client.serverURL?.absoluteString ?? "—")
                LabeledContent("User", value: session.userName ?? "—")
            }

            Section {
                // Only worth offering once there is somewhere to switch to;
                // with one account it is a button that shows you yourself.
                if session.accounts.count > 1 {
                    Button("Switch User") {
                        session.showAccountPicker()
                    }
                    .settingsAction()
                }
                Button("Add Account") {
                    session.addAccount()
                }
                .settingsAction()
                // Signing out forgets this account, because logout revokes
                // the token server-side and a remembered dead session is
                // worse than none. Other accounts are untouched (HEL-38).
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
                .settingsAction()
            }

            Section("About") {
                LabeledContent("App", value: "Lagoon")
                LabeledContent("Version", value: session.client.appVersion)
            }

            Section("Debug") {
                // tvOS gets a button rather than a switch: a `Toggle` in a
                // tvOS Form has the same invisible-title problem and no
                // `.button` toggle style to escape it (HEL-62). State reads
                // through the checkmark — content, not chrome.
                #if os(tvOS)
                Button {
                    showPlaybackHUD.toggle()
                } label: {
                    Label(
                        "Playback HUD",
                        systemImage: showPlaybackHUD ? "checkmark.circle.fill" : "circle"
                    )
                }
                .settingsAction()
                #else
                Toggle("Playback HUD", isOn: $showPlaybackHUD)
                #endif
            }
        }
        #if os(iOS)
        .navigationTitle("Settings")
        #endif
    }
}

private extension View {
    /// tvOS `Form` rows do not flip their label colour under the system's
    /// focused white lozenge, so a *default-styled* control's title renders
    /// white-on-white and vanishes exactly when it matters (HEL-62).
    ///
    /// Giving the control an explicit style restores the flip — verified in
    /// the simulator, where the same button is invisible focused without it
    /// and legible with it. The clear row background is the other half:
    /// without it the pill sits inside the row's own plate, which reads as
    /// two stacked buttons.
    ///
    /// iOS is untouched: `Form` behaves there, and a pill per row would
    /// look nothing like a settings screen.
    @ViewBuilder
    func settingsAction() -> some View {
        #if os(tvOS)
        buttonStyle(.glass).listRowBackground(Color.clear)
        #else
        self
        #endif
    }

}
