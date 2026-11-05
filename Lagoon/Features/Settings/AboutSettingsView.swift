import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AboutSettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var showingWhatsNew = false

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        TVSettingsPage(
            "About",
            description: "Which build of Lagoon this is, and the server and device it is running against."
        ) {
            TVSettingsSection("Application") {
                ApplicationInfoRows(includesIdentifier: true)

                Button {
                    showingWhatsNew = true
                } label: {
                    TVSettingsRowLabel("What's New", value: whatsNewDetail)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.about.whatsnew")
            }

            // Shared with the sign-in screens' About sheet. Legal info must not need an account.
            LegalSettingsSection()

            TVSettingsSection("Server") {
                ForEach(serverRows, id: \.title) { row in
                    TVSettingsRowLabel(LocalizedStringKey(row.title), value: row.value)
                }
            }

            TVSettingsSection("Device") {
                ForEach(deviceRows, id: \.title) { row in
                    TVSettingsRowLabel(LocalizedStringKey(row.title), value: row.value)
                }
            }
        }
        .sheet(isPresented: $showingWhatsNew) {
            // No NavigationStack on tvOS: its title has no background and it
            // halves the sheet's width.
            WhatsNewView()
        }
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneBody: some View {
        TouchSettingsPage("About") {
            Section("Application") {
                ApplicationInfoRows(includesIdentifier: true)
                Button("What's New") { showingWhatsNew = true }
                    .accessibilityIdentifier("settings.about.whatsnew")
            }
            LegalSettingsSection()
            Section("Server") {
                ForEach(serverRows, id: \.title) { row in
                    LabeledContent(row.title, value: row.value)
                }
            }
            Section("Device") {
                ForEach(deviceRows, id: \.title) { row in
                    LabeledContent(row.title, value: row.value)
                }
            }
        }
        .sheet(isPresented: $showingWhatsNew) {
            NavigationStack { WhatsNewView() }
        }
    }
    #endif

    // MARK: - Rows

    private struct Row {
        let title: String
        let value: String
    }

    private var serverRows: [Row] {
        [
            Row(title: "Jellyfin", value: session.serverName ?? "—"),
            Row(title: "Address", value: session.client.serverURL?.host() ?? "—"),
            Row(title: "Signed In As", value: session.userName ?? "—"),
        ]
    }

    private var deviceRows: [Row] {
        #if canImport(UIKit)
        [
            Row(title: "Model", value: UIDevice.current.model),
            Row(
                title: "System",
                value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            ),
        ]
        #else
        []
        #endif
    }

    private var whatsNewDetail: String {
        Changelog.runningBuildIsListed()
            ? Changelog.runningDisplayVersion()
            : String(localized: "This build isn't listed")
    }
}

/// The application's name, version and build, shared by Settings → About and
/// the sign-in screens' About sheet. Rows go inside the caller's section.
struct ApplicationInfoRows: View {
    /// Settings → About also lists the bundle identifier.
    var includesIdentifier = false

    private var rows: [(title: String, value: String)] {
        var rows = [
            (title: "Name", value: "Lagoon"),
            (title: "Version", value: Changelog.version()),
            (title: "Build", value: Changelog.build()),
        ]
        if includesIdentifier {
            rows.append((title: "Identifier", value: Bundle.main.bundleIdentifier ?? "—"))
        }
        return rows
    }

    var body: some View {
        ForEach(rows, id: \.title) { row in
            #if os(tvOS)
            TVSettingsRowLabel(LocalizedStringKey(row.title), value: row.value)
            #else
            LabeledContent(row.title, value: row.value)
            #endif
        }
    }
}
