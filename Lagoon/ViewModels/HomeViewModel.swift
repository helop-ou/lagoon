import Foundation
import Observation

@Observable
final class HomeViewModel {
    struct LibraryRail: Identifiable {
        let id: String
        let title: String
        let items: [MediaItem]
        var style: RailStyle = .poster
    }

    /// Plugin sections whose content Lagoon already draws with a rail of its
    /// own (HEL-47). Rendering these as well is the failure mode the
    /// catalogue invites: a real server offers `ContinueWatching`,
    /// `NextUp` *and* `ContinueWatchingNextUp` at once, plus `Latest*`
    /// alongside `RecentlyAdded*` — Home would show the same films three
    /// times over. `MyMedia` is the library list, which is the tab bar here.
    static let nativelyCoveredSections: Set<String> = [
        "ContinueWatching", "NextUp", "ContinueWatchingNextUp", "MyMedia",
        "LatestMovies", "LatestShows", "RecentlyAddedMovies", "RecentlyAddedShows",
    ]

    var resume: [MediaItem] = []
    var nextUp: [MediaItem] = []
    var favorites: [MediaItem] = []
    /// Extra rails contributed by the Home Screen Sections plugin, already
    /// deduped and stripped of empties. Empty on servers without it.
    var pluginRails: [LibraryRail] = []
    var latestRails: [LibraryRail] = []
    var heroItems: [MediaItem] = []
    var isLoading = true
    var errorMessage: String?

    private var hasLoaded = false
    private var loadedAccountID: String?
    private var loadGeneration = 0

    func load(
        client: JellyfinClient,
        accountID: String? = nil,
        homeSectionPreferences: HomeSectionPreferenceValues = HomeSectionPreferenceValues()
    ) async {
        if loadedAccountID != accountID {
            clearForAccountChange()
            loadedAccountID = accountID
        }
        guard !hasLoaded else { return }
        hasLoaded = true
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        do {
            let libraries = try await client.userViews()
                .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }

            async let resumeItems = try? client.resumeItems()
            async let nextUpItems = try? client.nextUp()
            // Never fatal to the screen: a server that dislikes the filter
            // should cost you the rail, not the whole of Home.
            async let favoriteItems = try? client.favorites()

            var rails: [LibraryRail] = []
            await withTaskGroup(of: (Int, LibraryRail)?.self) { group in
                for (index, library) in libraries.enumerated() {
                    group.addTask {
                        guard let items = try? await client.latest(parentId: library.id) else { return nil }
                        let title = "Recently Added" + (library.name.map { " in \($0)" } ?? "")
                        return (index, LibraryRail(id: library.id, title: title, items: items))
                    }
                }
                var collected: [(Int, LibraryRail)] = []
                for await entry in group {
                    if let entry { collected.append(entry) }
                }
                rails = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            let resolvedResume = await resumeItems ?? []
            let resolvedNextUp = await nextUpItems ?? []
            let resolvedFavorites = await favoriteItems ?? []
            let resolvedPluginRails = await loadPluginRails(
                client: client,
                preferences: homeSectionPreferences
            )
            guard generation == loadGeneration else { return }
            resume = resolvedResume
            nextUp = resolvedNextUp
            favorites = resolvedFavorites
            latestRails = rails
            TopShelfStore.publish(resume, client: client)
            pluginRails = resolvedPluginRails
            heroItems = Array(
                rails.flatMap(\.items)
                    .filter { $0.backdropImageTags?.isEmpty == false && $0.overview != nil }
                    .shuffled()
                    .prefix(6)
            )
        } catch {
            guard generation == loadGeneration else { return }
            hasLoaded = false
            errorMessage = "Couldn't load your library."
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    func retry(
        client: JellyfinClient,
        accountID: String? = nil,
        homeSectionPreferences: HomeSectionPreferenceValues = HomeSectionPreferenceValues()
    ) async {
        hasLoaded = false
        await load(
            client: client,
            accountID: accountID,
            homeSectionPreferences: homeSectionPreferences
        )
    }

    /// Cheap re-fetch of the user-data-driven rails: on returning from
    /// playback, and after a card's context menu marks something watched or
    /// favourited (HEL-40). All three rails are derived from user data, so
    /// any one of those mutations can move an item between them.
    func refreshProgress(client: JellyfinClient) async {
        guard hasLoaded, !isLoading else { return }
        async let resumeItems = client.resumeItems()
        async let nextUpItems = client.nextUp()
        async let favoriteItems = try? client.favorites()
        if let refreshed = try? await (resume: resumeItems, nextUp: nextUpItems) {
            resume = refreshed.resume
            nextUp = refreshed.nextUp
        }
        favorites = await favoriteItems ?? favorites
        TopShelfStore.publish(resume, client: client)
    }

    func refreshPluginRails(
        client: JellyfinClient,
        preferences: HomeSectionPreferenceValues
    ) async {
        guard hasLoaded, !isLoading else { return }
        let generation = loadGeneration
        let rails = await loadPluginRails(client: client, preferences: preferences)
        guard generation == loadGeneration else { return }
        pluginRails = rails
    }

    /// Fetches whatever the Home Screen Sections plugin adds beyond Lagoon's
    /// own rails (HEL-47). Costs nothing on a server without the plugin: the
    /// catalogue call 404s and this returns immediately.
    ///
    /// Empty sections are dropped rather than rendered, because the
    /// catalogue lists every type the plugin knows — a movies-and-TV server
    /// still advertises Books, Music and Jellyseerr rows. Measured against a
    /// real server, all 28 sections resolve in under two seconds
    /// concurrently, and the empty ones answer in ~0.1 s each.
    private func loadPluginRails(
        client: JellyfinClient,
        preferences: HomeSectionPreferenceValues
    ) async -> [LibraryRail] {
        let sections = HomeSectionPreferenceResolver.sections(
            from: await client.homeSections(),
            preferences: preferences,
            nativelyCovered: Self.nativelyCoveredSections
        )
        guard !sections.isEmpty else { return [] }

        return await withTaskGroup(of: (index: Int, rail: LibraryRail)?.self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask {
                    let items = await client.homeSectionItems(section.section)
                    guard !items.isEmpty else { return nil }
                    return (
                        index: index,
                        rail: LibraryRail(
                            id: "plugin-" + section.section,
                            title: section.displayText ?? section.section,
                            items: items,
                            // Square has no rail of its own; the poster rail
                            // is the closer fit of the two Lagoon has.
                            style: section.viewMode == "Landscape" ? .landscape : .poster
                        )
                    )
                }
            }
            var collected: [(index: Int, rail: LibraryRail)] = []
            for await entry in group {
                if let entry { collected.append(entry) }
            }
            return collected.sorted { $0.index < $1.index }.map(\.rail)
        }
    }

    private func clearForAccountChange() {
        loadGeneration &+= 1
        hasLoaded = false
        resume = []
        nextUp = []
        favorites = []
        pluginRails = []
        latestRails = []
        heroItems = []
        errorMessage = nil
    }
}
