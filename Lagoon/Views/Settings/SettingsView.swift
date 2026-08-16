import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    #if DEBUG
    @AppStorage("debug.playbackHUD") private var showPlaybackHUD = false
    @AppStorage("debug.mpvForMKV") private var mpvForMKV = false
    #endif

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

            #if DEBUG
            Section("Debug") {
                Toggle("Playback HUD", isOn: $showPlaybackHUD)
                Toggle("mpv engine for MKV (experimental)", isOn: $mpvForMKV)
            }
            #endif
        }
        #if os(iOS)
        .navigationTitle("Settings")
        #endif
    }
}
