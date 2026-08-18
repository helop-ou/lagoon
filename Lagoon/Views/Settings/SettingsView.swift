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
                }
                Button("Add Account") {
                    session.addAccount()
                }
                // Signing out forgets this account, because logout revokes
                // the token server-side and a remembered dead session is
                // worse than none. Other accounts are untouched (HEL-38).
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
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
        #if os(iOS)
        .navigationTitle("Settings")
        #endif
    }
}
