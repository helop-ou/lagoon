import Foundation
import Observation

@Observable
final class HomeViewModel {
    struct LibraryRail: Identifiable {
        let id: String
        let title: String
        let items: [MediaItem]
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
    /// Native movie and show discovery shelves. Keeping their catalogues and
    /// artwork samples separate prevents a shared genre name from opening a
    /// mixed Movie/Series grid.
    var movieGenreShelf: [GenreShelfItem] = []
    var showGenreShelf: [GenreShelfItem] = []
    var heroItems: [MediaItem] = []
    /// The curated rows (HEL-120), each carrying its own title because two of
    /// them name what they are about: the title they are similar to, and the
    /// genre or decade the rotation landed on today.
    var curatedRails: [String: LibraryRail] = [:]
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
            async let movieGenreCatalog = try? client.genres(includeTypes: [.movie])
            async let showGenreCatalog = try? client.genres(includeTypes: [.series])
            async let movieGenreArtworkCandidates = try? client.items(
                includeTypes: [.movie],
                sortBy: "CommunityRating",
                sortOrder: "Descending",
                limit: 300,
                fields: "Genres,CommunityRating,PrimaryImageAspectRatio"
            )
            async let showGenreArtworkCandidates = try? client.items(
                includeTypes: [.series],
                sortBy: "CommunityRating",
                sortOrder: "Descending",
                limit: 300,
                fields: "Genres,CommunityRating,PrimaryImageAspectRatio"
            )

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
            let resolvedMovieGenres = await movieGenreCatalog ?? []
            let resolvedShowGenres = await showGenreCatalog ?? []
            let resolvedMovieGenreCandidates = await movieGenreArtworkCandidates?.items ?? []
            let resolvedShowGenreCandidates = await showGenreArtworkCandidates?.items ?? []
            let resolvedPluginRails = await loadPluginRails(
                client: client,
                preferences: homeSectionPreferences
            )
            guard generation == loadGeneration else { return }
            resume = resolvedResume
            nextUp = resolvedNextUp
            favorites = resolvedFavorites
            movieGenreShelf = GenreShelfResolver.resolve(
                catalog: resolvedMovieGenres,
                candidates: resolvedMovieGenreCandidates,
                includeTypes: [.movie]
            )
            showGenreShelf = GenreShelfResolver.resolve(
                catalog: resolvedShowGenres,
                candidates: resolvedShowGenreCandidates,
                includeTypes: [.series]
            )
            latestRails = rails
            TopShelfStore.publish(resume, client: client)
            pluginRails = resolvedPluginRails
            heroItems = Array(
                rails.flatMap(\.items)
                    .filter { $0.backdropImageTags?.isEmpty == false && $0.overview != nil }
                    .shuffled()
                    .prefix(6)
            )
            // Deliberately not awaited. These are discovery rather than the
            // reason anyone opened Lagoon, and awaiting them here would hold
            // `isLoading` — and so the entire screen, hero included — behind
            // eight queries for rows that are below the fold anyway. They
            // appear as they resolve.
            Task { await loadCuratedRails(client: client, generation: generation) }
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
    /// The curated rows (HEL-120), fetched together and published together.
    ///
    /// Every one of these is discovery: nice to have, never the reason
    /// someone opened Lagoon. They are fetched concurrently and applied in
    /// one assignment after the rails that matter are already on screen, and
    /// any that fails simply does not appear — an unreachable row must cost a
    /// row, not the screen.
    private func loadCuratedRails(client: JellyfinClient, generation: Int) async {
        // What they actually watch, which decides the genre spotlight.
        let played = (try? await client.items(
            includeTypes: [.movie, .series],
            sortBy: "DatePlayed",
            sortOrder: "Descending",
            limit: 60,
            filters: ["IsPlayed"]
        ))?.items ?? []
        guard generation == loadGeneration else { return }

        let today = Date.now
        let genre = HomeRotation.genre(
            rankedByWatchHistory: HomeRotation.rankGenres(byWatchHistory: played),
            for: today
        )
        let decade = HomeRotation.decade(for: today)

        async let similar = similarRail(seeds: played, client: client)
        async let highlyRated = rail(
            id: HomeCuratedRows.ID.highlyRated,
            title: "Highly Rated, Unseen",
            client: client,
            sortBy: "CommunityRating",
            sortOrder: "Descending",
            filters: ["IsUnplayed"],
            minCommunityRating: HomeCuratedRows.minimumCommunityRating
        )
        async let fourK = rail(
            id: HomeCuratedRows.ID.inFourK,
            title: "In 4K",
            client: client,
            sortBy: "DateCreated",
            sortOrder: "Descending",
            is4K: true
        )
        async let genreRail = spotlightRail(genre: genre, client: client)
        async let decadeRail = spotlightRail(decade: decade, client: client)
        async let unstarted = rail(
            id: HomeCuratedRows.ID.unstartedSeries,
            title: "Series You Haven't Started",
            client: client,
            includeTypes: [.series],
            sortBy: "DateCreated",
            sortOrder: "Descending",
            filters: ["IsUnplayed"]
        )
        async let binge = rail(
            id: HomeCuratedRows.ID.readyToBinge,
            title: "Ready to Binge",
            client: client,
            includeTypes: [.series],
            sortBy: "CommunityRating",
            sortOrder: "Descending",
            filters: ["IsUnplayed"],
            seriesStatus: "Ended"
        )
        async let surprise = rail(
            id: HomeCuratedRows.ID.surpriseMe,
            title: "Surprise Me",
            client: client,
            sortBy: "Random",
            filters: ["IsUnplayed"]
        )

        let resolved = await [
            similar,
            highlyRated,
            fourK,
            genreRail,
            decadeRail,
            unstarted,
            binge,
            surprise,
        ].compactMap(\.self)

        guard generation == loadGeneration else { return }
        curatedRails = Dictionary(
            resolved.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    /// Today's genre, or nothing when the viewer has watched too little for
    /// the rotation to have an opinion.
    private func spotlightRail(genre: String?, client: JellyfinClient) async -> LibraryRail? {
        guard let genre else { return nil }
        return await rail(
            id: HomeCuratedRows.ID.genreSpotlight,
            title: "More \(genre)",
            client: client,
            sortBy: "Random",
            genres: [genre],
            filters: ["IsUnplayed"]
        )
    }

    /// Movies only: a decade of television is a different proposition, and
    /// mixing them makes the row about nothing in particular.
    private func spotlightRail(decade year: Int?, client: JellyfinClient) async -> LibraryRail? {
        guard let year else { return nil }
        return await rail(
            id: HomeCuratedRows.ID.decadeSpotlight,
            title: HomeRotation.decadeTitle(startingIn: year),
            client: client,
            includeTypes: [.movie],
            sortBy: "CommunityRating",
            years: Array(year..<(year + 10))
        )
    }

    /// "Because You Watched X". The title names its own reason, which is the
    /// whole point of the row — an unexplained shelf of vaguely related films
    /// is what every other client already has.
    ///
    /// Seeds are tried in the order they were watched, skipping anything too
    /// short to have been a viewing, and the first that returns a full rail
    /// wins. See `minimumSeedRuntime` for what that filter is really for.
    private func similarRail(seeds: [MediaItem], client: JellyfinClient) async -> LibraryRail? {
        let candidates = seeds
            .filter { HomeCuratedRows.isSubstantialSeed($0) }
            .prefix(HomeCuratedRows.seedAttempts)

        for seed in candidates {
            guard let items = try? await client.similarItems(itemId: seed.id, limit: 16),
                  items.count >= HomeCuratedRows.minimumItems
            else { continue }
            return LibraryRail(
                id: HomeCuratedRows.ID.becauseYouWatched,
                title: "Because You Watched \(seed.railTitle)",
                items: items
            )
        }
        return nil
    }

    /// Nil rather than an empty rail when a query fails or returns too little
    /// to look deliberate, so the caller never has to decide what counts.
    private func rail(
        id: String,
        title: String,
        client: JellyfinClient,
        includeTypes: [MediaItemType] = [.movie, .series],
        sortBy: String,
        sortOrder: String = "Descending",
        genres: [String] = [],
        filters: [String] = [],
        years: [Int] = [],
        is4K: Bool? = nil,
        minCommunityRating: Double? = nil,
        seriesStatus: String? = nil
    ) async -> LibraryRail? {
        guard let page = try? await client.items(
            includeTypes: includeTypes,
            sortBy: sortBy,
            sortOrder: sortOrder,
            genres: genres,
            limit: 16,
            filters: filters,
            years: years,
            is4K: is4K,
            minCommunityRating: minCommunityRating,
            seriesStatus: seriesStatus
        ), page.items.count >= HomeCuratedRows.minimumItems else { return nil }
        return LibraryRail(id: id, title: title, items: page.items)
    }

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
                            items: items
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
        movieGenreShelf = []
        showGenreShelf = []
        pluginRails = []
        latestRails = []
        heroItems = []
        // Otherwise the previous account's "Because You Watched" survives the
        // switch, which names a title on someone else's screen.
        curatedRails = [:]
        errorMessage = nil
    }
}
