import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    // Deliberately visible in Release too: TestFlight is the only way to
    // exercise mpv/HDR on real hardware, and that needs these switches.
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Server", value: session.serverName ?? "Jellyfin")
                LabeledContent("Address", value: session.client.serverURL?.absoluteString ?? "—")
                LabeledContent("User", value: session.userName ?? "—")
            }

            Section {
                Button("Sign Out") {
                    Task { await session.signOut() }
                }
                Button("Change Server", role: .destructive) {
                    Task { await session.forgetServer() }
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
