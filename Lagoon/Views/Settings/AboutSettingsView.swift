import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What this build is, what it is talking to, and what changed in it.
struct AboutSettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var showingChangelog = false

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
                ForEach(applicationRows, id: \.title) { row in
                    TVSettingsActionLabel(LocalizedStringKey(row.title), value: row.value)
                }

                Button {
                    showingChangelog = true
                } label: {
                    TVSettingsActionLabel("Changelog", value: changelogDetail)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.about.changelog")
            }

            TVSettingsSection("Server") {
                ForEach(serverRows, id: \.title) { row in
                    TVSettingsActionLabel(LocalizedStringKey(row.title), value: row.value)
                }
            }

            TVSettingsSection("Device") {
                ForEach(deviceRows, id: \.title) { row in
                    TVSettingsActionLabel(LocalizedStringKey(row.title), value: row.value)
                }
            }
        }
        .sheet(isPresented: $showingChangelog) {
            // A modal rather than another pushed page: the changelog is
            // something you glance at and dismiss.
            //
            // No NavigationStack on tvOS. Its title has no background of its
            // own, so the notes scrolled visibly behind it, and it was also
            // what squeezed the sheet to roughly half its natural width. The
            // panel draws its own header and footer bars instead.
            //
            // `presentationSizing` has no effect on a tvOS sheet with custom
            // content — .form and .page render identically — so the sheet
            // takes the size it wants. Narrowing it would mean drawing panel
            // chrome by hand, which is not worth it.
            ChangelogView()
                .frame(
                    width: Metrics.modalPanelSize.width,
                    height: Metrics.modalPanelSize.height
                )
                .presentationSizing(.fitted)
        }
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneBody: some View {
        Form {
            Section("Application") {
                ForEach(applicationRows, id: \.title) { row in
                    LabeledContent(row.title, value: row.value)
                }
                Button("Changelog") { showingChangelog = true }
            }
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
        .navigationTitle("About")
        .sheet(isPresented: $showingChangelog) {
            NavigationStack { ChangelogView() }
        }
    }
    #endif

    // MARK: - Rows

    private struct Row {
        let title: String
        let value: String
    }

    private var applicationRows: [Row] {
        [
            Row(title: "Name", value: "Lagoon"),
            Row(title: "Version", value: Changelog.version()),
            Row(title: "Build", value: Changelog.build()),
            Row(
                title: "Identifier",
                value: Bundle.main.bundleIdentifier ?? "—"
            ),
        ]
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

    private var changelogDetail: String {
        Changelog.runningBuildIsListed()
            ? Changelog.entries.first?.displayVersion ?? ""
            : String(localized: "This build isn't listed")
    }
}

/// Every shipped build, newest first.
struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        // A plain three-part stack — title, scrolling notes, Done — rather
        // than safeAreaInset overlays. Insets draw *over* the content, so the
        // button sat on top of the notes, and giving the bars their own
        // material to hide that painted two darker rectangles across the
        // sheet's single blurred surface. Laid out in sequence, each part
        // gets its own space and the whole panel shares one background.
        VStack(spacing: 0) {
            Text("Changelog")
                .font(.title3.bold())
                .padding(Metrics.Space.l)

            notes

            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .padding(Metrics.Space.l)
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("settings.changelog")
        #else
        notes
            .navigationTitle("Changelog")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("settings.changelog")
        #endif
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                if !Changelog.runningBuildIsListed() {
                    // TestFlight assigns build numbers at upload, so the
                    // running build often has no entry. Say so rather than
                    // showing a list that silently omits it.
                    Text("You're running \(Changelog.version()) (\(Changelog.build())), which has no changelog entry yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(Changelog.entries) { entry in
                    VStack(alignment: .leading, spacing: Metrics.Space.m) {
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.m) {
                            Text(entry.displayVersion)
                                .font(.title3.bold())
                            if Changelog.isRunning(entry) {
                                Text("Installed")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, Metrics.Space.s)
                                    .padding(.vertical, Metrics.Space.xs)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            Spacer(minLength: 0)
                            Text(entry.released)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.headline)
                            .font(.callout.weight(.medium))

                        VStack(alignment: .leading, spacing: Metrics.Space.s) {
                            ForEach(entry.changes, id: \.self) { change in
                                HStack(alignment: .top, spacing: Metrics.Space.s) {
                                    Text("•")
                                    Text(change)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                #if os(tvOS)
                                // tvOS scrolls by moving focus, so a panel of
                                // plain text cannot be scrolled at all —
                                // everything below the fold was unreachable.
                                // Each note is its own focus target; the
                                // scroll view follows focus down the list.
                                .focusable()
                                #endif
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Metrics.Space.xl)
            .padding(.bottom, Metrics.Space.xl)
        }
    }
}
