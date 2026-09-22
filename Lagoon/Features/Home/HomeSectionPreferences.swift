import Foundation
import Observation
import SwiftUI

nonisolated struct HomeSectionPreferenceRow: Codable, Equatable, Identifiable {
    let id: String
    var isEnabled: Bool
}

/// Ids for the non-curated Home rows (curated ones are in `HomeCuratedRows.ID`).
/// Persisted per account: renaming one would restore a row someone hid.
nonisolated enum HomeRowID {
    static let continueWatching = "lagoon.continueWatching"
    static let nextUp = "lagoon.nextUp"
    static let favorites = "lagoon.favorites"
    static let recentlyAddedMovies = "lagoon.recentlyAddedMovies"
    static let recentlyAddedShows = "lagoon.recentlyAddedShows"
    static let recentlyAddedOther = "lagoon.recentlyAddedOther"
    static let movieGenres = "lagoon.movieGenres"
    static let showGenres = "lagoon.showGenres"

    /// The old single toggle for all three Recently Added rows. Read only.
    static let legacyRecentlyAdded = "lagoon.recentlyAdded"

    /// Native row ids start with this; plugin rows use the server's section name.
    static let nativePrefix = "lagoon."

    /// Keeps a plugin section named like a library id from colliding with a
    /// Recently Added rail.
    static let pluginRailPrefix = "plugin-"

    static func isNative(_ id: String) -> Bool { id.hasPrefix(nativePrefix) }

    static func pluginRailID(forSection section: String) -> String {
        pluginRailPrefix + section
    }

    static func section(forPluginRailID id: String) -> String {
        String(id.dropFirst(pluginRailPrefix.count))
    }
}

nonisolated struct HomeSectionPreferenceValues: Codable, Equatable {
    /// Every Home row, native and plugin, in draw order.
    ///
    /// Stays empty until the viewer arranges something, so an update can
    /// change the default order for everyone else. Once set, it wins and new
    /// rows are reconciled into it.
    var layout: [HomeSectionPreferenceRow] = []

    init(layout: [HomeSectionPreferenceRow] = []) {
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case layout
    }

    /// Legacy shape: ordered plugin rows plus hide-only native overrides.
    private enum LegacyCodingKeys: String, CodingKey {
        case isConfigured
        case rows
        case nativeRows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try container.decodeIfPresent([HomeSectionPreferenceRow].self, forKey: .layout) {
            layout = stored
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        layout = HomeSectionPreferenceResolver.migratedLayout(
            isConfigured: try legacy.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false,
            pluginRows: try legacy.decodeIfPresent([HomeSectionPreferenceRow].self, forKey: .rows) ?? [],
            nativeRows: try legacy.decodeIfPresent([HomeSectionPreferenceRow].self, forKey: .nativeRows) ?? []
        )
    }

    /// Rows missing from the arrangement are shown, so a newly added row
    /// appears before Settings reconciles it.
    func isEnabled(_ id: String) -> Bool {
        layout.first(where: { $0.id == id })?.isEnabled ?? true
    }

    var isCustomized: Bool { !layout.isEmpty }
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
    /// Every native row, in default order. This list is the default layout:
    /// moving a row here moves it on screen.
    static let nativeChoices: [HomeSectionChoice] = [
        HomeSectionChoice(
            id: HomeRowID.continueWatching,
            title: "Continue Watching",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeRowID.nextUp,
            title: "Next Up",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeRowID.recentlyAddedMovies,
            title: "Recently Added Movies",
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
            id: HomeRowID.recentlyAddedShows,
            title: "Recently Added Shows",
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
            id: HomeCuratedRows.ID.becauseYouWatched,
            title: "Because You Watched",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeRowID.favorites,
            title: "Favorites",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeCuratedRows.ID.highlyRated,
            title: "Great Movies You Haven't Seen",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeCuratedRows.ID.inFourK,
            title: "Movies in 4K",
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
            id: HomeRowID.movieGenres,
            title: "Movie Genres",
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
            id: HomeCuratedRows.ID.readyToBinge,
            title: "Ready to Binge",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeRowID.showGenres,
            title: "Show Genres",
            isEnabled: true,
            source: .lagoon
        ),
        HomeSectionChoice(
            id: HomeRowID.recentlyAddedOther,
            title: "Recently Added in Other Libraries",
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

    static let defaultLayout: [HomeSectionPreferenceRow] = nativeChoices.map {
        HomeSectionPreferenceRow(id: $0.id, isEnabled: true)
    }

    static let nativeIDs: Set<String> = Set(nativeChoices.map(\.id))

    /// The three rows the single legacy Recently Added toggle became.
    private static let recentlyAddedIDs: Set<String> = [
        HomeRowID.recentlyAddedMovies,
        HomeRowID.recentlyAddedShows,
        HomeRowID.recentlyAddedOther,
    ]

    /// Folds a legacy layout into the single ordered list. Hidden rows and
    /// plugin order carry over; native order does not, since nobody chose it.
    static func migratedLayout(
        isConfigured: Bool,
        pluginRows: [HomeSectionPreferenceRow],
        nativeRows: [HomeSectionPreferenceRow]
    ) -> [HomeSectionPreferenceRow] {
        let hidden = Set(nativeRows.filter { !$0.isEnabled }.map(\.id))
        guard isConfigured || !hidden.isEmpty else { return [] }

        var layout = nativeChoices.map { choice in
            HomeSectionPreferenceRow(id: choice.id, isEnabled: !wasHidden(choice.id, in: hidden))
        }
        var seen = nativeIDs
        layout.append(contentsOf: pluginRows.filter { seen.insert($0.id).inserted })
        return layout
    }

    private static func wasHidden(_ id: String, in hidden: Set<String>) -> Bool {
        if hidden.contains(id) { return true }
        // One toggle governed all three, so all three inherit its answer.
        return recentlyAddedIDs.contains(id) && hidden.contains(HomeRowID.legacyRecentlyAdded)
    }

    /// Keeps the first of any duplicate sections the server returns, so
    /// dictionaries and identified SwiftUI rows cannot trap on them.
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

    /// Brings an arrangement up to date. Only ever adds rows: a failed
    /// `homeSections()` returns an empty catalogue, and pruning would wipe
    /// the viewer's arrangement.
    static func reconciled(
        _ layout: [HomeSectionPreferenceRow],
        sections: [String]
    ) -> [HomeSectionPreferenceRow] {
        guard !layout.isEmpty else { return [] }
        var seen = Set<String>()
        var rows = layout.filter { seen.insert($0.id).inserted }

        // New native rows go to their default position, not the bottom.
        for (index, choice) in nativeChoices.enumerated() where !seen.contains(choice.id) {
            let preceding = nativeChoices[..<index].reversed().first { seen.contains($0.id) }
            let destination = preceding
                .flatMap { anchor in rows.firstIndex { $0.id == anchor.id }.map { $0 + 1 } } ?? 0
            rows.insert(HomeSectionPreferenceRow(id: choice.id, isEnabled: true), at: destination)
            seen.insert(choice.id)
        }

        // New plugin sections arrive shown until the viewer has arranged a
        // plugin row; after that they arrive hidden.
        let hasArrangedPluginRows = rows.contains { !HomeRowID.isNative($0.id) }
        for section in sections where seen.insert(section).inserted {
            rows.append(HomeSectionPreferenceRow(id: section, isEnabled: !hasArrangedPluginRows))
        }
        return rows
    }

    /// Every placeable row in draw order, hidden ones included; the default
    /// order until the viewer arranges their own.
    static func arrangement(
        preferences: HomeSectionPreferenceValues,
        pluginSections: [String]
    ) -> [HomeSectionPreferenceRow] {
        reconciled(
            preferences.layout.isEmpty ? defaultLayout : preferences.layout,
            sections: pluginSections
        )
    }

    /// The plugin sections worth fetching, in the order they will be drawn.
    static func sections(
        from catalog: [JellyfinClient.HomeSection],
        preferences: HomeSectionPreferenceValues,
        nativelyCovered: Set<String>
    ) -> [JellyfinClient.HomeSection] {
        let offerable = orderedUniqueCatalog(catalog).filter { !nativelyCovered.contains($0.section) }
        let byID = Dictionary(
            offerable.map { ($0.section, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return arrangement(preferences: preferences, pluginSections: offerable.map(\.section))
            .compactMap { $0.isEnabled ? byID[$0.id] : nil }
    }

    /// The ids Home draws, in order. `pluginSections` are those that resolved
    /// to a rail.
    static func renderOrder(
        preferences: HomeSectionPreferenceValues,
        pluginSections: [String]
    ) -> [String] {
        arrangement(preferences: preferences, pluginSections: pluginSections)
            .filter(\.isEnabled)
            .map(\.id)
    }
}

/// The viewer's Home layout, native and plugin rows alike, stored per account
/// (server and user).
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
            catalog = Self.offerable(Self.settingsRegressionCatalog)
            reconcile()
            return
        }
        #endif
        let fetched = await client.homeSections()
        guard !Task.isCancelled else { return }
        catalog = Self.offerable(fetched)
        reconcile()
    }

    /// Sections Lagoon draws natively are not offered twice.
    private static func offerable(
        _ catalog: [JellyfinClient.HomeSection]
    ) -> [JellyfinClient.HomeSection] {
        HomeSectionPreferenceResolver.orderedUniqueCatalog(catalog)
            .filter { !HomeViewModel.nativelyCoveredSections.contains($0.section) }
    }

    /// Rows for the settings screen, hidden ones included. A remembered plugin
    /// row the server no longer offers stays in the arrangement but not here.
    var choices: [HomeSectionChoice] {
        let nativeTitles = Dictionary(
            HomeSectionPreferenceResolver.nativeChoices.map { ($0.id, $0.title) },
            uniquingKeysWith: { current, _ in current }
        )
        let pluginTitles = Dictionary(
            catalog.map { ($0.section, $0.displayText ?? $0.section) },
            uniquingKeysWith: { current, _ in current }
        )
        return arrangement.compactMap { row in
            if let title = nativeTitles[row.id] {
                return HomeSectionChoice(
                    id: row.id, title: title, isEnabled: row.isEnabled, source: .lagoon
                )
            }
            guard let title = pluginTitles[row.id] else { return nil }
            return HomeSectionChoice(
                id: row.id, title: title, isEnabled: row.isEnabled, source: .plugin
            )
        }
    }

    func toggle(_ id: String) {
        adoptArrangement()
        guard let index = values.layout.firstIndex(where: { $0.id == id }) else { return }
        values.layout[index].isEnabled.toggle()
        persist()
    }

    func move(_ id: String, by offset: Int) {
        adoptArrangement()
        let visibleIDs = choices.map(\.id)
        guard let source = visibleIDs.firstIndex(of: id) else { return }
        let destination = source + offset
        guard visibleIDs.indices.contains(destination) else { return }
        // `IndexSet` moves insert before the destination, so moving down needs +1.
        move(
            fromOffsets: IndexSet(integer: source),
            toOffset: offset > 0 ? destination + 1 : destination
        )
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        adoptArrangement()
        // Reorder only the visible rows; unnamed remembered rows stay put.
        var visibleIDs = choices.map(\.id)
        guard offsets.allSatisfy({ visibleIDs.indices.contains($0) }),
              (0...visibleIDs.count).contains(destination) else { return }
        visibleIDs.move(fromOffsets: offsets, toOffset: destination)
        let byID = Dictionary(values.layout.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = Set(visibleIDs)
        var reordered = visibleIDs.makeIterator()
        values.layout = values.layout.map { row in
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

    private var arrangement: [HomeSectionPreferenceRow] {
        HomeSectionPreferenceResolver.arrangement(
            preferences: values,
            pluginSections: catalog.map(\.section)
        )
    }

    /// Saves the shown order as the account's own before a move or toggle.
    /// Until then the account has no layout and follows the default.
    private func adoptArrangement() {
        let adopted = arrangement
        guard adopted != values.layout else { return }
        values.layout = adopted
    }

    private func reconcile() {
        let reconciled = HomeSectionPreferenceResolver.reconciled(
            values.layout,
            sections: catalog.map(\.section)
        )
        guard reconciled != values.layout else { return }
        values.layout = reconciled
        persist()
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
        // MyList is duplicated on purpose: real servers do this, and it crashed.
        let data = Data(#"{"Items":[{"Section":"ContinueWatching","DisplayText":"Continue Watching","OrderIndex":0},{"Section":"MyList","DisplayText":"My List","OrderIndex":1},{"Section":"MyList","DisplayText":"Duplicate My List","OrderIndex":2},{"Section":"Recommendations","DisplayText":"Recommendations","OrderIndex":3}]}"#.utf8)
        return (try? JellyfinClient.decoder.decode(Page.self, from: data).items) ?? []
    }
    #endif
}

struct HomeRowsSettingsView: View {
    @Bindable var preferences: HomeSectionPreferencesStore

    private var description: String {
        """
        Choose which rows appear on Home and what order they appear in. \
        Rows Lagoon provides itself sit alongside any your server's Home \
        Screen Sections plugin adds.
        """
    }

    var body: some View {
        #if os(tvOS)
        TVSettingsPage("Home Rows", description: description) {
            TVSettingsSection("Rows") {
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
                                Image(systemName: choice.isEnabled ? "checkmark.circle.fill" : "circle")
                                    .opacity(choice.isEnabled ? 1 : 0.55)
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
            Section {
                ForEach(preferences.choices) { choice in
                    Toggle(isOn: Binding(
                        get: { choice.isEnabled },
                        set: { _ in preferences.toggle(choice.id) }
                    )) {
                        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                            Text(choice.title)
                            Text(choice.source.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.home.row.\(choice.id)")
                }
                .onMove(perform: preferences.move(fromOffsets:toOffset:))
            } footer: {
                Text("Tap Edit to change the order rows appear in.")
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
        .toolbar { EditButton() }
        #endif
    }
}
