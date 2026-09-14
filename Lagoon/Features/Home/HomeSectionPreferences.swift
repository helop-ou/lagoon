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
    /// Native rows are enabled by default. Only explicit overrides are
    /// persisted so accounts saved before native toggles existed retain the
    /// original all-visible Home layout.
    var nativeRows: [HomeSectionPreferenceRow] = []

    init(
        isConfigured: Bool = false,
        rows: [HomeSectionPreferenceRow] = [],
        nativeRows: [HomeSectionPreferenceRow] = []
    ) {
        self.isConfigured = isConfigured
        self.rows = rows
        self.nativeRows = nativeRows
    }

    private enum CodingKeys: String, CodingKey {
        case isConfigured
        case rows
        case nativeRows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isConfigured = try container.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false
        rows = try container.decodeIfPresent([HomeSectionPreferenceRow].self, forKey: .rows) ?? []
        nativeRows = try container.decodeIfPresent([HomeSectionPreferenceRow].self, forKey: .nativeRows) ?? []
    }

    func isNativeEnabled(_ id: String) -> Bool {
        nativeRows.first(where: { $0.id == id })?.isEnabled ?? true
    }

    var isCustomized: Bool {
        isConfigured || nativeRows.contains(where: { !$0.isEnabled })
    }
}

nonisolated enum HomeRowSource: String, Equatable, Sendable {
    case lagoon = "Lagoon Native"
    case plugin = "Home Screen Sections"
}

nonisolated struct HomeSectionChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isEnabled: Bool
    let source: HomeRowSource
}

nonisolated enum HomeSectionPreferenceResolver {
    /// Rows rendered directly by Lagoon rather than fetched through the
    /// optional Home Screen Sections plugin. They remain visible here even
    /// on servers without the plugin so ownership is never ambiguous.
    static var nativeChoices: [HomeSectionChoice] {
        [
            HomeSectionChoice(
                id: "lagoon.continueWatching",
                title: "Continue Watching",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: "lagoon.nextUp",
                title: "Next Up",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: "lagoon.favorites",
                title: "Favorites",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: "lagoon.movieGenres",
                title: "Movie Genres",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: "lagoon.showGenres",
                title: "Show Genres",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: "lagoon.recentlyAdded",
                title: "Recently Added",
                isEnabled: true,
                source: .lagoon
            ),
            // The curated rows (HEL-120), listed in the order Home draws them
            // so this screen reads as a map of that one.
            HomeSectionChoice(
                id: HomeCuratedRows.ID.becauseYouWatched,
                title: "Because You Watched",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.highlyRated,
                title: "Highly Rated, Unseen",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.topMovies,
                title: "Top 10 Movies",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.inFourK,
                title: "In 4K",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.genreSpotlight,
                title: "Genre Spotlight",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.decadeSpotlight,
                title: "Decade Spotlight",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.unstartedSeries,
                title: "Series You Haven't Started",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.topShows,
                title: "Top 10 Shows",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.readyToBinge,
                title: "Ready to Binge",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: CollectionShelf.rowID,
                title: "Collections",
                isEnabled: true,
                source: .lagoon
            ),
            HomeSectionChoice(
                id: HomeCuratedRows.ID.surpriseMe,
                title: "Surprise Me",
                isEnabled: true,
                source: .lagoon
            ),
        ]
    }

    /// The plugin catalogue is server-owned input. Keep the first copy of a
    /// section when a server returns duplicate identifiers so neither the
    /// dictionary lookup nor SwiftUI's identified rows can trap on them.
    static func orderedUniqueCatalog(
        _ catalog: [JellyfinClient.HomeSection]
    ) -> [JellyfinClient.HomeSection] {
        let ordered = catalog.enumerated().sorted { lhs, rhs in
            let lhsOrder = lhs.element.orderIndex ?? lhs.offset
            let rhsOrder = rhs.element.orderIndex ?? rhs.offset
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map(\.element)

        var seen = Set<String>()
        return ordered.filter { seen.insert($0.section).inserted }
    }

    static func sections(
        from catalog: [JellyfinClient.HomeSection],
        preferences: HomeSectionPreferenceValues,
        nativelyCovered: Set<String>
    ) -> [JellyfinClient.HomeSection] {
        let orderedCatalog = orderedUniqueCatalog(catalog)
        guard preferences.isConfigured else {
            return orderedCatalog.filter { !nativelyCovered.contains($0.section) }
        }

        let byID = Dictionary(
            orderedCatalog.map { ($0.section, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var selected = Set<String>()
        return preferences.rows.compactMap { row in
            guard row.isEnabled, selected.insert(row.id).inserted else { return nil }
            return byID[row.id]
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
            catalog = HomeSectionPreferenceResolver.orderedUniqueCatalog(Self.settingsRegressionCatalog)
            reconcileConfiguredRows()
            return
        }
        #endif
        let fetched = await client.homeSections()
        guard !Task.isCancelled else { return }
        catalog = HomeSectionPreferenceResolver.orderedUniqueCatalog(fetched)
        reconcileConfiguredRows()
    }

    var choices: [HomeSectionChoice] {
        let byID = Dictionary(
            catalog.map { ($0.section, $0) },
            uniquingKeysWith: { current, _ in current }
        )
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
                isEnabled: row.isEnabled,
                source: .plugin
            )
        }
    }

    var nativeChoices: [HomeSectionChoice] {
        HomeSectionPreferenceResolver.nativeChoices.map { choice in
            HomeSectionChoice(
                id: choice.id,
                title: choice.title,
                isEnabled: values.isNativeEnabled(choice.id),
                source: choice.source
            )
        }
    }

    func toggleNative(_ id: String) {
        guard HomeSectionPreferenceResolver.nativeChoices.contains(where: { $0.id == id }) else {
            return
        }
        if let index = values.nativeRows.firstIndex(where: { $0.id == id }) {
            // Enabled is the default, so remove a restored row's override.
            if values.nativeRows[index].isEnabled {
                values.nativeRows[index].isEnabled = false
            } else {
                values.nativeRows.remove(at: index)
            }
        } else {
            values.nativeRows.append(HomeSectionPreferenceRow(id: id, isEnabled: false))
        }
        persist()
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

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        ensureConfigured()
        // Missing plugin rows remain remembered, but have no index in the
        // visible List. Reorder only the rows represented by its move action.
        var visibleIDs = choices.map(\.id)
        guard offsets.allSatisfy({ visibleIDs.indices.contains($0) }),
              (0...visibleIDs.count).contains(destination) else { return }
        visibleIDs.move(fromOffsets: offsets, toOffset: destination)
        let byID = Dictionary(values.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = Set(visibleIDs)
        var reordered = visibleIDs.makeIterator()
        values.rows = values.rows.map { row in
            guard visible.contains(row.id), let id = reordered.next() else { return row }
            return byID[id] ?? row
        }
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
            },
            nativeRows: values.nativeRows
        )
    }

    private func reconcileConfiguredRows() {
        guard values.isConfigured else { return }
        let known = Set(catalog.map(\.section))
        var seen = Set<String>()
        var rows = values.rows.filter {
            known.contains($0.id) && seen.insert($0.id).inserted
        }
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
        // MyList is deliberately duplicated to keep the real-server crash
        // path covered by the tvOS navigation regression test.
        let data = Data(#"{"Items":[{"Section":"ContinueWatching","DisplayText":"Continue Watching","OrderIndex":0},{"Section":"MyList","DisplayText":"My List","OrderIndex":1},{"Section":"MyList","DisplayText":"Duplicate My List","OrderIndex":2},{"Section":"Recommendations","DisplayText":"Recommendations","OrderIndex":3}]}"#.utf8)
        return (try? JellyfinClient.decoder.decode(Page.self, from: data).items) ?? []
    }
    #endif
}

struct HomeRowsSettingsView: View {
    @Bindable var preferences: HomeSectionPreferencesStore

    var body: some View {
        #if os(tvOS)
        TVSettingsPage(
            "Home Rows",
            description: "See which Home rows Lagoon provides itself and choose which optional Home Screen Sections plugin rows appear after them."
        ) {
            TVSettingsSection(
                "Lagoon Native",
                footer: "These rows are built into Lagoon and work without the Home Screen Sections plugin."
            ) {
                ForEach(preferences.nativeChoices) { choice in
                    HomeNativeRow(choice: choice) {
                        preferences.toggleNative(choice.id)
                    }
                }
            }

            TVSettingsSection(
                "Home Screen Sections Plugin",
                footer: preferences.choices.isEmpty
                    ? "This server does not expose any Home Screen Sections plugin rows."
                    : "Turn plugin rows on or off and arrange their order after Lagoon's native rows."
            ) {
                if preferences.choices.isEmpty {
                    Text("No plugin rows available")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.Space.m)
                }
                ForEach(Array(preferences.choices.enumerated()), id: \.element.id) { index, choice in
                    HStack(spacing: Metrics.Space.m) {
                        Button {
                            preferences.toggle(choice.id)
                        } label: {
                            HStack(spacing: Metrics.Space.l) {
                                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                                    Text(choice.title)
                                    Text("\(choice.source.rawValue) · \(choice.isEnabled ? "Shown" : "Hidden")")
                                        .font(.caption)
                                        .opacity(0.7)
                                }
                                Spacer(minLength: Metrics.Space.xl)
                                Text(choice.isEnabled ? "Shown" : "Hidden")
                                    .opacity(0.7)
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

            if preferences.values.isCustomized {
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
        ThemedForm {
            Section("Lagoon Native") {
                ForEach(preferences.nativeChoices) { choice in
                    Toggle(choice.title, isOn: Binding(
                        get: { choice.isEnabled },
                        set: { _ in preferences.toggleNative(choice.id) }
                    ))
                    .accessibilityIdentifier("settings.home.native.\(choice.id)")
                }
            }

            Section {
                if preferences.choices.isEmpty {
                    Text("No plugin rows available on this server.")
                        .foregroundStyle(.secondary)
                }
                ForEach(preferences.choices) { choice in
                    Toggle(choice.title, isOn: Binding(
                        get: { choice.isEnabled },
                        set: { _ in preferences.toggle(choice.id) }
                    ))
                    .accessibilityIdentifier("settings.home.row.\(choice.id)")
                }
                .onMove(perform: preferences.move(fromOffsets:toOffset:))
            } header: {
                Text("Home Screen Sections Plugin")
            } footer: {
                Text("Plugin rows appear after Lagoon's native rows. Tap Edit to change their order.")
            }

            if preferences.values.isCustomized {
                Section {
                    Button("Reset to Lagoon Default", role: .destructive) {
                        preferences.reset()
                    }
                }
            }
        }
        .navigationTitle("Home Rows")
        .toolbar {
            if !preferences.choices.isEmpty {
                EditButton()
            }
        }
        #endif
    }
}

#if os(tvOS)
private struct HomeNativeRow: View {
    let choice: HomeSectionChoice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Space.xl) {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(choice.title)
                    Text("\(choice.source.rawValue) · \(choice.isEnabled ? "Shown" : "Hidden")")
                        .font(.caption)
                        .opacity(0.7)
                }
                Spacer(minLength: Metrics.Space.xl)
                Image(systemName: choice.isEnabled ? "checkmark.circle.fill" : "circle")
                    .opacity(choice.isEnabled ? 1 : 0.55)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .accessibilityValue(choice.isEnabled ? "Shown" : "Hidden")
        .accessibilityIdentifier("settings.home.native.\(choice.id)")
    }
}
#endif
