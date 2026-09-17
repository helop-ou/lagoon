import Foundation
import Observation
import SwiftUI

nonisolated struct HomeSectionPreferenceRow: Codable, Equatable, Identifiable {
    let id: String
    var isEnabled: Bool
}

/// Identifiers for the Home rows that are not curated rows, which carry their
/// own in `HomeCuratedRows.ID`. Stable strings for the same reason: they are
/// persisted per account, and renaming one would silently restore a row
/// someone had hidden or moved.
nonisolated enum HomeRowID {
    static let continueWatching = "lagoon.continueWatching"
    static let nextUp = "lagoon.nextUp"
    static let favorites = "lagoon.favorites"
    static let recentlyAddedMovies = "lagoon.recentlyAddedMovies"
    static let recentlyAddedShows = "lagoon.recentlyAddedShows"
    static let recentlyAddedOther = "lagoon.recentlyAddedOther"
    static let movieGenres = "lagoon.movieGenres"
    static let showGenres = "lagoon.showGenres"

    /// One toggle governed all three Recently Added rows before HEL-191 made
    /// them individually placeable. Only read, never written.
    static let legacyRecentlyAdded = "lagoon.recentlyAdded"

    /// Every native row's identifier begins with this. A plugin row is
    /// identified by its server-defined section name, which does not.
    static let nativePrefix = "lagoon."

    /// `HomeViewModel.LibraryRail` namespaces plugin rails so a section named
    /// after a library id cannot collide with a Recently Added rail.
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
    /// Every Home row, native and plugin alike, in the order Home draws them.
    ///
    /// Empty until the viewer arranges something, and that emptiness is load
    /// bearing: it is what lets a Lagoon update change the default order, and
    /// introduce rows into the middle of it, for everyone who has never opened
    /// the screen. Once it holds an arrangement, the arrangement wins and new
    /// rows are reconciled into it instead (HEL-191).
    var layout: [HomeSectionPreferenceRow] = []

    init(layout: [HomeSectionPreferenceRow] = []) {
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case layout
    }

    /// The shape written before HEL-191: a plugin-only ordered list, plus
    /// hide-only overrides for native rows that had no order of their own.
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

    /// Rows absent from an arrangement are shown, which is what keeps a row
    /// added by a later Lagoon build visible before Settings has reconciled it.
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
    /// Every row Lagoon draws itself, in the order it draws them by default.
    ///
    /// This list is the default layout, not a description of one written
    /// somewhere else: Home renders whatever order it resolves to, so a row
    /// moved here moves on screen. The shape is the one HEL-191 settled on —
    /// what you were watching, then what each library just gained and what is
    /// popular in it, then a movie block and a show block each closing with
    /// its genre shelf, then the exits that belong to no single subject.
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

    /// The three rows the single pre-HEL-191 Recently Added toggle became.
    private static let recentlyAddedIDs: Set<String> = [
        HomeRowID.recentlyAddedMovies,
        HomeRowID.recentlyAddedShows,
        HomeRowID.recentlyAddedOther,
    ]

    /// Folds a layout saved before HEL-191 into the single ordered list.
    ///
    /// Hidden rows are carried over and the plugin rows keep the order they
    /// were given, after the native block, which is where they rendered. The
    /// native order deliberately is *not* carried over: it was never a choice
    /// anyone made, so an account that had only hidden a row adopts the new
    /// default order with that row still hidden.
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

    /// Brings an arrangement up to date with the rows that exist now.
    ///
    /// A row is never dropped, only ever added. `homeSections()` answers a
    /// failed request with an empty catalogue, and a reconcile that pruned
    /// unknown rows would take a viewer's arrangement with it the first time
    /// the server was slow.
    static func reconciled(
        _ layout: [HomeSectionPreferenceRow],
        sections: [String]
    ) -> [HomeSectionPreferenceRow] {
        guard !layout.isEmpty else { return [] }
        var seen = Set<String>()
        var rows = layout.filter { seen.insert($0.id).inserted }

        // A row a Lagoon update added belongs where it was designed to go,
        // not at the bottom under the server's plugin rows.
        for (index, choice) in nativeChoices.enumerated() where !seen.contains(choice.id) {
            let preceding = nativeChoices[..<index].reversed().first { seen.contains($0.id) }
            let destination = preceding
                .flatMap { anchor in rows.firstIndex { $0.id == anchor.id }.map { $0 + 1 } } ?? 0
            rows.insert(HomeSectionPreferenceRow(id: choice.id, isEnabled: true), at: destination)
            seen.insert(choice.id)
        }

        // An arrangement that has never held a plugin row has never arranged
        // one, so the server's sections arrive shown — that is an account that
        // had only hidden a native row before HEL-191, and every plugin row it
        // was showing keeps showing. Once one has been arranged, a section the
        // server gained later arrives hidden instead: an arrangement is a
        // decision, and a row appearing in the middle of one was nobody's.
        let hasArrangedPluginRows = rows.contains { !HomeRowID.isNative($0.id) }
        for section in sections where seen.insert(section).inserted {
            rows.append(HomeSectionPreferenceRow(id: section, isEnabled: !hasArrangedPluginRows))
        }
        return rows
    }

    /// Every row this account can place, in the order Home draws them,
    /// including the ones it is hiding. The default order stands in until the
    /// viewer has arranged anything of their own.
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

    /// The identifiers Home draws, in order.
    ///
    /// `pluginSections` are the sections that resolved to a rail, already in
    /// the order `sections(from:preferences:nativelyCovered:)` chose.
    static func renderOrder(
        preferences: HomeSectionPreferenceValues,
        pluginSections: [String]
    ) -> [String] {
        arrangement(preferences: preferences, pluginSections: pluginSections)
            .filter(\.isEnabled)
            .map(\.id)
    }
}

/// The viewer's Home layout: which rows appear and in what order, across both
/// Lagoon's own rows and the optional Home Screen Sections plugin's. The
/// account id already combines server URL and Jellyfin user id, which prevents
/// choices leaking between servers or profiles (HEL-60).
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

    /// Sections Lagoon already draws itself are not offered: the native row is
    /// the one that is placeable and toggleable, and a second entry naming the
    /// same content would be two controls over one row.
    private static func offerable(
        _ catalog: [JellyfinClient.HomeSection]
    ) -> [JellyfinClient.HomeSection] {
        HomeSectionPreferenceResolver.orderedUniqueCatalog(catalog)
            .filter { !HomeViewModel.nativelyCoveredSections.contains($0.section) }
    }

    /// Every row the viewer can place, in the order Home draws them, hidden
    /// ones included — this screen is where a hidden row is brought back.
    ///
    /// A remembered row whose plugin section this server no longer offers has
    /// no title to show, so it is held in the arrangement but left out here.
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
        // `IndexSet` moves insert *before* the destination, so a downward move
        // has to clear the row it is passing.
        move(
            fromOffsets: IndexSet(integer: source),
            toOffset: offset > 0 ? destination + 1 : destination
        )
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        adoptArrangement()
        // A remembered row this server cannot name is still in the
        // arrangement, but has no index in the visible List. Reorder only the
        // rows its move action represents, and leave the rest where they sit.
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

    /// Every row in the order Home draws it, standing in the default order for
    /// an account that has never arranged one of its own.
    private var arrangement: [HomeSectionPreferenceRow] {
        HomeSectionPreferenceResolver.arrangement(
            preferences: values,
            pluginSections: catalog.map(\.section)
        )
    }

    /// Writes the order this screen is showing into the account's own
    /// arrangement, so a move or a toggle acts on the rows the viewer can see.
    /// Until this runs, a never-arranged account holds no layout at all and
    /// the default is free to change under it.
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
        // MyList is deliberately duplicated to keep the real-server crash
        // path covered by the tvOS navigation regression test.
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
