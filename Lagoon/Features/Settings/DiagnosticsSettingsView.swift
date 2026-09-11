import SwiftUI

struct DiagnosticsSettingsView: View {
    @Binding var showPlaybackHUD: Bool
    @Binding var diagnosticReports: Bool
    @Binding var frameLossBench: Bool
    @Binding var stripDoviEL: Bool
    @Binding var bufferTranscodes: Bool
    #if DEBUG
    @Binding var simulateAudioStarvation: Bool
    @Binding var simulateDeliveryStall: Bool
    @Binding var bufferOnAudioStarvation: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        remoteSettings
        #else
        touchSettings
        #endif
    }

    #if os(tvOS)
    private var remoteSettings: some View {
        TVSettingsPage(
            "Advanced",
            description: "Tools for diagnosing playback compatibility. Leave them off during normal viewing."
        ) {
            TVSettingsSection(
                "Playback Diagnostics",
                footer: "These options can affect playback behavior and are intended for troubleshooting. Dolby Vision Compatibility Mode plays Dolby Vision profile 7 titles as HDR10 from the base layer; off (default), Lagoon converts them to Dolby Vision profile 8.1."
            ) {
                TVSettingsToggle("Show Playback Details", isOn: $showPlaybackHUD)
                    .accessibilityIdentifier("settings.diagnostics.hud")
                TVSettingsToggle("Run Playback Performance Test", isOn: $frameLossBench)
                    .accessibilityIdentifier("settings.diagnostics.frameLoss")
                TVSettingsToggle("Dolby Vision Compatibility Mode", isOn: $stripDoviEL)
                    .accessibilityIdentifier("settings.diagnostics.dovi")
                TVSettingsToggle("Buffer Transcoded Playback", isOn: $bufferTranscodes)
                    .accessibilityIdentifier("settings.diagnostics.transcodeCache")
                #if DEBUG
                TVSettingsToggle("Simulate Audio Starvation", isOn: $simulateAudioStarvation)
                    .accessibilityIdentifier("settings.diagnostics.audioStarvation")
                TVSettingsToggle("Simulate Delivery Stall", isOn: $simulateDeliveryStall)
                    .accessibilityIdentifier("settings.diagnostics.deliveryStall")
                TVSettingsToggle("Buffer on Audio Starvation", isOn: $bufferOnAudioStarvation)
                    .accessibilityIdentifier("settings.diagnostics.audioBuffering")
                #endif
            }

            TVSettingsSection(
                "Diagnostic Reports",
                footer: Self.diagnosticReportsFooter
            ) {
                TVSettingsToggle("Send Diagnostic Reports", isOn: $diagnosticReports)
                    .accessibilityIdentifier("settings.diagnostics.reports")
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
    #else
    private var touchSettings: some View {
        TouchSettingsPage("Advanced") {
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
                Text("These options can affect playback behavior and are intended for troubleshooting. Leave them off during normal viewing. Dolby Vision Compatibility Mode plays Dolby Vision profile 7 titles as HDR10 from the base layer; off (default), Lagoon converts them to Dolby Vision profile 8.1.")
            }

            Section {
                Toggle("Send Diagnostic Reports", isOn: $diagnosticReports)
                    .accessibilityIdentifier("settings.diagnostics.reports")
            } header: {
                Text("Diagnostic Reports")
            } footer: {
                Text(Self.diagnosticReportsFooter)
            }
        }
    }
    #endif

    /// What a report contains, stated the way it is collected (HEL-159).
    /// Kept in one string so both platforms make the same promise.
    private static let diagnosticReportsFooter: LocalizedStringKey = "When playback or a server request fails unexpectedly, Lagoon sends a technical report to the developer: app build, device model and OS version, codec and delivery details, error codes, and about a minute of playback measurements. Reports never include your account, server address, media titles, subtitles, or screenshots. Reports are kept for 30 days."
}
