import Foundation
import Observation
import SwiftUI

nonisolated struct HomeSectionPreferenceRow: Codable, Equatable, Identifiable {
    let id: String
    var isEnabled: Bool
}

nonisolated struct HomeSectionPreferenceValues: Codable, Equatable {
    var isConfigured = false
    var rows: [HomeSectionPreferenceRow] = []
}

nonisolated struct HomeSectionChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let isEnabled: Bool
}

nonisolated enum HomeSectionPreferenceResolver {
    static func sections(
        from catalog: [JellyfinClient.HomeSection],
        preferences: HomeSectionPreferenceValues,
        nativelyCovered: Set<String>
    ) -> [JellyfinClient.HomeSection] {
        let orderedCatalog = catalog.enumerated().sorted {
            ($0.element.orderIndex ?? $0.offset) < ($1.element.orderIndex ?? $1.offset)
        }.map(\.element)
        guard preferences.isConfigured else {
            return orderedCatalog.filter { !nativelyCovered.contains($0.section) }
        }

        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.section, $0) })
        return preferences.rows.compactMap { row in
            row.isEnabled ? byID[row.id] : nil
        }
    }
}

/// Local layout for the optional Home Screen Sections plugin. The account id
/// already combines server URL and Jellyfin user id, which prevents choices
/// leaking between servers or profiles (HEL-60).
@MainActor
@Observable
final class HomeSectionPreferencesStore {
    private(set) var accountID: String?
    private(set) var catalog: [JellyfinClient.HomeSection] = []
    private(set) var values = HomeSectionPreferenceValues()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        catalog = []
        values = Self.savedValues(accountID: accountID, defaults: defaults)
    }

    func loadCatalog(client: JellyfinClient) async {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.settingsRegression") {
            catalog = Self.settingsRegressionCatalog
            reconcileConfiguredRows()
            return
        }
        #endif
        let fetched = await client.homeSections()
        guard !Task.isCancelled else { return }
        catalog = fetched.enumerated().sorted {
            ($0.element.orderIndex ?? $0.offset) < ($1.element.orderIndex ?? $1.offset)
        }.map(\.element)
        reconcileConfiguredRows()
    }

    var choices: [HomeSectionChoice] {
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.section, $0) })
        let rows: [HomeSectionPreferenceRow]
        if values.isConfigured {
            rows = values.rows
        } else {
            rows = catalog.map {
                HomeSectionPreferenceRow(
                    id: $0.section,
                    isEnabled: !HomeViewModel.nativelyCoveredSections.contains($0.section)
                )
            }
        }
        return rows.compactMap { row in
            guard let section = byID[row.id] else { return nil }
            return HomeSectionChoice(
                id: row.id,
                title: section.displayText ?? section.section,
                isEnabled: row.isEnabled
            )
        }
    }

    func toggle(_ id: String) {
        ensureConfigured()
        guard let index = values.rows.firstIndex(where: { $0.id == id }) else { return }
        values.rows[index].isEnabled.toggle()
        persist()
    }

    func move(_ id: String, by offset: Int) {
        ensureConfigured()
        guard let source = values.rows.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard values.rows.indices.contains(destination) else { return }
        values.rows.swapAt(source, destination)
        persist()
    }

    func reset() {
        values = HomeSectionPreferenceValues()
        guard let accountID else { return }
        defaults.removeObject(forKey: Self.key(accountID))
    }

    static func savedValues(
        accountID: String?,
        defaults: UserDefaults = .standard
    ) -> HomeSectionPreferenceValues {
        guard let accountID,
              let data = defaults.data(forKey: key(accountID)),
              let decoded = try? JSONDecoder().decode(HomeSectionPreferenceValues.self, from: data) else {
            return HomeSectionPreferenceValues()
        }
        return decoded
    }

    private func ensureConfigured() {
        guard !values.isConfigured else { return }
        values = HomeSectionPreferenceValues(
            isConfigured: true,
            rows: catalog.map {
                HomeSectionPreferenceRow(
                    id: $0.section,
                    isEnabled: !HomeViewModel.nativelyCoveredSections.contains($0.section)
                )
            }
        )
    }

    private func reconcileConfiguredRows() {
        guard values.isConfigured else { return }
        let known = Set(catalog.map(\.section))
        var rows = values.rows.filter { known.contains($0.id) }
        let recorded = Set(rows.map(\.id))
        rows.append(contentsOf: catalog.compactMap { section in
            recorded.contains(section.section)
                ? nil
                : HomeSectionPreferenceRow(id: section.section, isEnabled: false)
        })
        if rows != values.rows {
            values.rows = rows
            persist()
        }
    }

    private func persist() {
        guard let accountID,
              let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key(accountID))
    }

    private nonisolated static func key(_ accountID: String) -> String {
        "home.sectionPreferences.\(accountID)"
    }

    #if DEBUG
    private static var settingsRegressionCatalog: [JellyfinClient.HomeSection] {
        struct Page: Decodable { let items: [JellyfinClient.HomeSection] }
        let data = Data(#"{"Items":[{"Section":"ContinueWatching","DisplayText":"Continue Watching","OrderIndex":0},{"Section":"MyList","DisplayText":"My List","OrderIndex":1},{"Section":"Recommendations","DisplayText":"Recommendations","OrderIndex":2}]}"#.utf8)
        return (try? JellyfinClient.decoder.decode(Page.self, from: data).items) ?? []
    }
    #endif
}

struct HomeRowsSettingsView: View {
    @Bindable var preferences: HomeSectionPreferencesStore

    var body: some View {
        #if os(tvOS)
        TVSettingsPage("Home Rows") {
            TVSettingsSection(
                "Rows",
                footer: "Choose which plugin rows appear after Lagoon's built-in rows, then arrange their order."
            ) {
                ForEach(Array(preferences.choices.enumerated()), id: \.element.id) { index, choice in
                    HStack(spacing: Metrics.Space.m) {
                        Button {
                            preferences.toggle(choice.id)
                        } label: {
                            HStack(spacing: Metrics.Space.l) {
                                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                                    Text(choice.title)
                                    Text(choice.isEnabled ? "Shown on Home" : "Hidden from Home")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Metrics.Space.xl)
                                Text(choice.isEnabled ? "Shown" : "Hidden")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                        .accessibilityValue(choice.isEnabled ? "Shown" : "Hidden")
                        .accessibilityIdentifier("settings.home.row.\(choice.id)")

                        Button {
                            preferences.move(choice.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.glass)
                        .disabled(index == 0)
                        .accessibilityLabel("Move \(choice.title) up")

                        Button {
                            preferences.move(choice.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.glass)
                        .disabled(index == preferences.choices.count - 1)
                        .accessibilityLabel("Move \(choice.title) down")
                    }
                }
            }

            if preferences.values.isConfigured {
                TVSettingsSection("Reset") {
                    Button("Reset to Lagoon Default", role: .destructive) {
                        preferences.reset()
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("settings.home.reset")
                }
            }
        }
        #else
        List {
            Section {
                ForEach(Array(preferences.choices.enumerated()), id: \.element.id) { index, choice in
                    HStack(spacing: Metrics.Space.m) {
                        Button {
                            preferences.toggle(choice.id)
                        } label: {
                            Label(
                                choice.title,
                                systemImage: choice.isEnabled ? "checkmark.circle.fill" : "circle"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityValue(choice.isEnabled ? "Shown" : "Hidden")

                        Button {
                            preferences.move(choice.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .accessibilityLabel("Move \(choice.title) up")

                        Button {
                            preferences.move(choice.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == preferences.choices.count - 1)
                        .accessibilityLabel("Move \(choice.title) down")
                    }
                }
            } footer: {
                Text("Turn plugin rows on or off and arrange the order they appear after Lagoon's built-in rows.")
            }

            if preferences.values.isConfigured {
                Section {
                    Button("Reset to Lagoon Default", role: .destructive) {
                        preferences.reset()
                    }
                }
            }
        }
        .navigationTitle("Home Rows")
        #endif
    }
}
