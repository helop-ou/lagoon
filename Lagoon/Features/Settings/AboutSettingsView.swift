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

            // Shared with the sign-in screens' About sheet; legal info must not need an account.
            LegalSettingsSection()

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
            // No NavigationStack on tvOS: its title has no background and it
            // halves the sheet's width. `presentationSizing` has no effect on
            // a tvOS sheet with custom content.
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
        ThemedForm {
            Section("Application") {
                ForEach(applicationRows, id: \.title) { row in
                    LabeledContent(row.title, value: row.value)
                }
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
        // A plain stack, not safeAreaInset overlays: insets draw over the
        // content, and giving them a material breaks the single background.
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
            .background(Theme.background.ignoresSafeArea())
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

    private var notes: some View {
        ScrollView {
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
            .padding(.horizontal, Metrics.Space.xl)
            .padding(.bottom, Metrics.Space.xl)
        }
    }
}
