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
    private static let nativelyCoveredSections: Set<String> = [
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

    func load(client: JellyfinClient) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        do {
            let libraries = try await client.userViews()
                .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }

            async let resumeItems = client.resumeItems()
            async let nextUpItems = client.nextUp()
            // Never fatal to the screen: a server that dislikes the filter
            // should cost you the rail, not the whole of Home.
            async let favoriteItems = try? client.favorites()

            var rails: [LibraryRail] = []
            try await withThrowingTaskGroup(of: (Int, LibraryRail).self) { group in
                for (index, library) in libraries.enumerated() {
                    group.addTask {
                        let items = try await client.latest(parentId: library.id)
                        let title = "Recently Added" + (library.name.map { " in \($0)" } ?? "")
                        return (index, LibraryRail(id: library.id, title: title, items: items))
                    }
                }
                var collected: [(Int, LibraryRail)] = []
                for try await entry in group {
                    collected.append(entry)
                }
                rails = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            resume = try await resumeItems
            nextUp = try await nextUpItems
            favorites = await favoriteItems ?? []
            latestRails = rails
            pluginRails = await loadPluginRails(client: client)
            heroItems = Array(
                rails.flatMap(\.items)
                    .filter { $0.backdropImageTags?.isEmpty == false && $0.overview != nil }
                    .shuffled()
                    .prefix(6)
            )
        } catch {
            hasLoaded = false
            errorMessage = "Couldn't load your library."
        }
        isLoading = false
    }

    func retry(client: JellyfinClient) async {
        hasLoaded = false
        await load(client: client)
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
    private func loadPluginRails(client: JellyfinClient) async -> [LibraryRail] {
        let sections = await client.homeSections()
            .filter { !Self.nativelyCoveredSections.contains($0.section) }
        guard !sections.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, LibraryRail)?.self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask {
                    let items = await client.homeSectionItems(section.section)
                    guard !items.isEmpty else { return nil }
                    return (
                        section.orderIndex ?? index,
                        LibraryRail(
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
            var collected: [(Int, LibraryRail)] = []
            for await entry in group {
                if let entry { collected.append(entry) }
            }
            // The plugin reports the same OrderIndex for every section on a
            // default install, so ties fall back to the catalogue's order.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
