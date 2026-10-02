import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
                ApplicationInfoRows(includesIdentifier: true)

                Button {
                    showingChangelog = true
                } label: {
                    TVSettingsRowLabel("Changelog", value: changelogDetail)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.about.changelog")
            }

            // Shared with the sign-in screens' About sheet; legal info must not need an account.
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
        .sheet(isPresented: $showingChangelog) {
            // No NavigationStack on tvOS: its title has no background and it
            // halves the sheet's width.
            ChangelogView()
        }
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneBody: some View {
        TouchSettingsPage("About") {
            Section("Application") {
                ApplicationInfoRows(includesIdentifier: true)
                Button("Changelog") { showingChangelog = true }
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

/// Every shipped build, newest first.
struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        TVModalPanel(title: Text("Changelog")) {
            notesContent
        }
        .accessibilityIdentifier("settings.changelog")
        #else
        ScrollView {
            notesContent
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.bottom, Metrics.Space.xl)
        }
        .themedPageBackground()
            .navigationTitle("Changelog")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("settings.changelog")
        #endif
    }

    /// Only the running build starts expanded.
    @State private var expanded: Set<String> = Set(
        Changelog.entries.filter { Changelog.isRunning($0) }.map(\.id)
    )

    private func toggle(_ entry: ChangelogEntry) {
        withAnimation(.easeInOut(duration: Motion.fast)) {
            if expanded.contains(entry.id) {
                expanded.remove(entry.id)
            } else {
                expanded.insert(entry.id)
            }
        }
    }

    private func entryHeader(_ entry: ChangelogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.m) {
            Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Metrics.Space.xs) {
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
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
            if !Changelog.runningBuildIsListed() {
                // A development build may have no entry yet.
                Text("You're running \(Changelog.version()) (\(Changelog.build())), which has no changelog entry yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Changelog.entries) { entry in
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Button {
                        toggle(entry)
                    } label: {
                        entryHeader(entry)
                    }
                    .accessibilityIdentifier("settings.changelog.\(entry.build)")

                    if expanded.contains(entry.id) {
                        VStack(alignment: .leading, spacing: Metrics.Space.l) {
                            ForEach(entry.sections) { section in
                                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                                    Text(LocalizedStringKey(section.category.rawValue))
                                        .accessibilityAddTraits(.isHeader)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    ForEach(section.changes, id: \.self) { change in
                                        HStack(alignment: .top, spacing: Metrics.Space.s) {
                                            Text("•")
                                                .accessibilityHidden(true)
                                            Text(change)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        #if os(tvOS)
                                        // tvOS scrolls by focus; unfocusable text cannot scroll.
                                        .focusable()
                                        #endif
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
