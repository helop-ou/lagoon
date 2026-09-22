import Foundation
import Observation

@Observable
final class HomeViewModel {
    struct LibraryRail: Identifiable {
        let id: String
        let title: String
        let items: [MediaItem]
        /// Files the rail under movies or shows. Nil for curated and plugin rails.
        var collectionType: String?
    }

    /// Plugin sections Lagoon already draws natively. Servers offer several
    /// overlapping ones at once, so showing them would repeat the same titles.
    /// `MyMedia` is the tab bar here.
    static let nativelyCoveredSections: Set<String> = [
        "ContinueWatching", "NextUp", "ContinueWatchingNextUp", "MyMedia",
        "LatestMovies", "LatestShows", "RecentlyAddedMovies", "RecentlyAddedShows",
    ]

    var resume: [MediaItem] = []
    var nextUp: [MediaItem] = []
    var favorites: [MediaItem] = []
    /// Rails from the Home Screen Sections plugin, deduped, empties removed.
    var pluginRails: [LibraryRail] = []
    var latestRails: [LibraryRail] = []
    /// Kept separate so a genre name shared by movies and shows never opens
    /// a mixed grid.
    var movieGenreShelf: [GenreShelfItem] = []
    var showGenreShelf: [GenreShelfItem] = []
    var heroItems: [MediaItem] = []
    /// Random library sample, fetched only when every other hero source is
    /// empty; kept so a refresh does not reshuffle the hero.
    private var librarySample: [MediaItem] = []
    var curatedRails: [String: LibraryRail] = [:]
    var collections: [CollectionShelfItem] = []
    var isLoading = true
    var errorMessage: String?

    private var hasLoaded = false
    private var loadedAccountID: String?
    private var loadGeneration = 0
    private var isRefreshing = false
    /// Discovery rails load after the primary content; held here so an
    /// account switch can cancel them.
    private var discoveryTasks: [Task<Void, Never>] = []

    func load(
        client: JellyfinClient,
        accountID: String? = nil,
        homeSectionPreferences: HomeSectionPreferenceValues = HomeSectionPreferenceValues(),
        seerr: SeerrClient? = nil
    ) async {
        guard !Task.isCancelled else { return }
        if loadedAccountID != accountID {
            clearForAccountChange()
            loadedAccountID = accountID
        }
        guard !hasLoaded else { return }
        hasLoaded = true
        let generation = loadGeneration
        let identity = client.sessionIdentity
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                if Task.isCancelled { hasLoaded = false }
            }
        }
        do {
            let libraries = try await client.userViews()
                .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }

            async let resumeItems = try? client.resumeItems()
            async let nextUpItems = try? client.nextUp()
            // A failure costs the rail, not the screen.
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

            let rails = await loadLatestRails(libraries: libraries, client: client)

            let resolvedResume = await resumeItems
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
            guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
            if let resolvedResume { resume = resolvedResume }
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
            if let resolvedResume { TopShelfStore.publish(resolvedResume, client: client, identity: identity) }
            pluginRails = resolvedPluginRails
            heroItems = HeroSelection.select(tiers: heroTiers)
            if heroItems.isEmpty {
                // No other hero source: sample the library so a dormant
                // server still opens on a hero.
                let sample = (try? await client.items(
                    includeTypes: [.movie, .series],
                    sortBy: "Random",
                    limit: 24
                ))?.items ?? []
                guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
                librarySample = sample
                heroItems = HeroSelection.select(tiers: heroTiers)
            }
            // Not awaited: holding `isLoading` for below-the-fold discovery
            // rows would delay the whole screen. They appear as they resolve.
            cancelDiscoveryTasks()
            discoveryTasks = [
                Task { [weak self] in
                    guard let self else { return }
                    await self.loadCuratedRails(
                        client: client,
                        generation: generation
                    )
                },
                Task { [weak self] in
                    guard let self else { return }
                    await self.loadTopTenRails(
                        client: client, seerr: seerr,
                        preferences: homeSectionPreferences, generation: generation
                    )
                },
                Task { [weak self] in
                    guard let self else { return }
                    await self.loadCollections(client: client, generation: generation)
                },
            ]
        } catch {
            guard generation == loadGeneration, identity == client.sessionIdentity else { return }
            hasLoaded = false
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn't load your library."
        }
    }

    func retry(
        client: JellyfinClient,
        accountID: String? = nil,
        homeSectionPreferences: HomeSectionPreferenceValues = HomeSectionPreferenceValues(),
        seerr: SeerrClient? = nil
    ) async {
        hasLoaded = false
        await load(
            client: client,
            accountID: accountID,
            homeSectionPreferences: homeSectionPreferences,
            seerr: seerr
        )
    }

    /// Re-fetches the user-data rails after playback or a watched/favourite
    /// change, which can move an item between them.
    func refreshProgress(client: JellyfinClient) async {
        guard hasLoaded, !isLoading else { return }
        let generation = loadGeneration
        let identity = client.sessionIdentity
        async let resumeItems = try? client.resumeItems()
        async let nextUpItems = try? client.nextUp()
        async let favoriteItems = try? client.favorites()
        let refreshed = await (resume: resumeItems, nextUp: nextUpItems)
        let refreshedFavorites = await favoriteItems
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
        if let refreshedResume = refreshed.resume {
            resume = refreshedResume
            TopShelfStore.publish(refreshedResume, client: client, identity: identity)
        }
        if let refreshedNextUp = refreshed.nextUp { nextUp = refreshedNextUp }
        if let refreshedFavorites {
            favorites = refreshedFavorites
        }
        // These are hero tiers too: refresh what is shown, fill gaps.
        heroItems = HeroSelection.refreshed(current: heroItems, tiers: heroTiers)
    }

    /// Reconciles Home after a foreground or refresh. Content stays mounted,
    /// and failed requests keep their last good value: a sleeping server must
    /// not turn Home into an error page.
    func refreshServerContent(
        client: JellyfinClient,
        homeSectionPreferences: HomeSectionPreferenceValues,
        seerr: SeerrClient? = nil
    ) async {
        guard hasLoaded, !isLoading, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Older discovery work must not land over this newer snapshot.
        cancelDiscoveryTasks()
        loadGeneration &+= 1
        let generation = loadGeneration

        async let progress: Void = refreshProgress(client: client)
        async let latest: Void = refreshLatestRails(client: client)
        async let plugin: Void = refreshPluginRails(
            client: client,
            preferences: homeSectionPreferences
        )
        async let curated: Void = loadCuratedRails(
            client: client,
            generation: generation
        )
        async let topTen: Void = loadTopTenRails(
            client: client, seerr: seerr,
            preferences: homeSectionPreferences, generation: generation
        )
        async let refreshedCollections: Void = loadCollections(
            client: client,
            generation: generation
        )
        _ = await (progress, latest, plugin, curated, topTen, refreshedCollections)
    }

    func refreshPluginRails(
        client: JellyfinClient,
        preferences: HomeSectionPreferenceValues
    ) async {
        guard hasLoaded, !isLoading else { return }
        let generation = loadGeneration
        let identity = client.sessionIdentity
        let rails = await loadPluginRails(client: client, preferences: preferences)
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
        pluginRails = rails
        if heroItems.isEmpty {
            heroItems = HeroSelection.select(tiers: heroTiers)
        }
    }

    private func refreshLatestRails(client: JellyfinClient) async {
        guard hasLoaded, !isLoading else { return }
        let generation = loadGeneration
        let identity = client.sessionIdentity
        guard let libraries = try? await client.userViews()
            .filter({ ["movies", "tvshows"].contains($0.collectionType ?? "") }) else { return }
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
        let refreshed = await loadLatestRails(libraries: libraries, client: client)
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }

        // A failed request keeps the rail's last value; a successful empty
        // one clears it.
        let freshByID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        let previousByID = Dictionary(uniqueKeysWithValues: latestRails.map { ($0.id, $0) })
        latestRails = libraries.compactMap { freshByID[$0.id] ?? previousByID[$0.id] }

        // Keep the hero's order, with fresh records and vacancies filled.
        heroItems = HeroSelection.refreshed(current: heroItems, tiers: heroTiers)
    }

    /// Hero sources in priority order; see `HeroSelection`. No collections:
    /// the hero routes to an item, not a collection page.
    private var heroTiers: [[MediaItem]] {
        [
            latestRails.flatMap(\.items),
            resume + nextUp,
            favorites,
            pluginRails.flatMap(\.items)
                + curatedRails.keys.sorted().flatMap { curatedRails[$0]?.items ?? [] },
            librarySample,
        ]
    }

    private func loadLatestRails(
        libraries: [MediaItem],
        client: JellyfinClient
    ) async -> [LibraryRail] {
        await withTaskGroup(of: (Int, LibraryRail)?.self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    let items: [MediaItem]
                    do {
                        items = if library.collectionType == "tvshows" {
                            try await client.latestSeries(parentId: library.id)
                        } else {
                            try await client.latest(parentId: library.id)
                        }
                    } catch {
                        return nil
                    }
                    let title = "Recently Added" + (library.name.map { " in \($0)" } ?? "")
                    return (index, LibraryRail(
                        id: library.id,
                        title: title,
                        items: items,
                        collectionType: library.collectionType
                    ))
                }
            }
            var collected: [(Int, LibraryRail)] = []
            for await entry in group {
                if let entry { collected.append(entry) }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Fetches the curated rows concurrently and publishes them in one
    /// assignment. A failed row just does not appear.
    private func loadCuratedRails(
        client: JellyfinClient,
        generation: Int
    ) async {
        let identity = client.sessionIdentity
        // Watch history decides the genre spotlight.
        let played = (try? await client.items(
            includeTypes: [.movie, .series],
            sortBy: "DatePlayed",
            sortOrder: "Descending",
            limit: 60,
            filters: ["IsPlayed"]
        ))?.items ?? []
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }

        let today = Date.now
        let genre = HomeRotation.genre(
            rankedByWatchHistory: HomeRotation.rankGenres(byWatchHistory: played),
            for: today
        )
        let decade = HomeRotation.decade(for: today)

        async let similar = similarRail(seeds: played, client: client)
        async let highlyRated = rail(
            id: HomeCuratedRows.ID.highlyRated,
            title: "Great Movies You Haven't Seen",
            client: client,
            includeTypes: [.movie],
            sortBy: "CommunityRating",
            sortOrder: "Descending",
            filters: ["IsUnplayed"],
            minCommunityRating: HomeCuratedRows.minimumCommunityRating
        )
        async let fourK = rail(
            id: HomeCuratedRows.ID.inFourK,
            title: "Movies in 4K",
            client: client,
            includeTypes: [.movie],
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
        // Mixes movies and shows, so it sits below both blocks.
        async let surprise = rail(
            id: HomeCuratedRows.ID.surpriseMe,
            title: "Surprise Me",
            client: client,
            includeTypes: [.movie, .series],
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
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
        // Top 10 loads separately so its scan never delays these; keep its rows.
        let topTen = curatedRails.filter {
            $0.key == HomeCuratedRows.ID.topMovies || $0.key == HomeCuratedRows.ID.topShows
        }
        curatedRails = Dictionary(
            resolved.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        ).merging(topTen, uniquingKeysWith: { current, _ in current })
        // An empty hero can still fill from the curated rows.
        if heroItems.isEmpty {
            heroItems = HeroSelection.select(tiers: heroTiers)
        }

    }

    /// Publishes independently of the other shelves but shares their generation.
    private func loadTopTenRails(
        client: JellyfinClient, seerr: SeerrClient?,
        preferences: HomeSectionPreferenceValues, generation: Int
    ) async {
        let identity = client.sessionIdentity
        let origin = seerr?.serverURL
        let cookie = seerr?.sessionCookie
        let enabled = preferences.isEnabled(HomeCuratedRows.ID.topMovies)
            || preferences.isEnabled(HomeCuratedRows.ID.topShows)
        let rails = await topTenRails(client: client, seerr: seerr?.sessionSnapshot(), enabled: enabled)
        guard generation == loadGeneration, identity == client.sessionIdentity,
              origin == seerr?.serverURL, cookie == seerr?.sessionCookie, !Task.isCancelled else { return }
        curatedRails.removeValue(forKey: HomeCuratedRows.ID.topMovies)
        curatedRails.removeValue(forKey: HomeCuratedRows.ID.topShows)
        for rail in rails { curatedRails[rail.id] = rail }
        if heroItems.isEmpty { heroItems = HeroSelection.select(tiers: heroTiers) }
    }

    /// The Collections row, in two passes. The list response carries
    /// `ChildCount`, so single-title stubs are dropped for free. Contents are
    /// fetched only for survivors without landscape art, to borrow a picture.
    private func loadCollections(client: JellyfinClient, generation: Int) async {
        let identity = client.sessionIdentity
        guard let all = try? await client.collections() else { return }
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }

        let ranked = CollectionShelf.ranked(all)
        guard !ranked.isEmpty else {
            collections = []
            return
        }

        let needsArtwork = ranked.filter { !CollectionShelf.hasLandscapeArtwork($0) }
        var borrowed: [String: MediaItem] = [:]
        await withTaskGroup(of: (String, MediaItem?).self) { group in
            for collection in needsArtwork {
                group.addTask {
                    let contents = (try? await client.collectionItems(
                        collectionId: collection.id,
                        limit: 8
                    )) ?? []
                    return (collection.id, CollectionShelf.artworkSource(from: contents))
                }
            }
            for await (id, artwork) in group {
                borrowed[id] = artwork
            }
        }

        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
        collections = CollectionShelf.shelf(ranked, borrowedArtwork: borrowed)
    }

    /// Nil when there is too little watch history to pick a genre.
    private func spotlightRail(genre: String?, client: JellyfinClient) async -> LibraryRail? {
        guard let genre else { return nil }
        return await rail(
            id: HomeCuratedRows.ID.genreSpotlight,
            // Home has no block headings, so the title says what it holds.
            title: "\(genre) Movies",
            client: client,
            includeTypes: [.movie],
            sortBy: "Random",
            genres: [genre],
            filters: ["IsUnplayed"]
        )
    }

    /// Movies only; mixing in television blurs the row.
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

    /// "Because You Watched X". Tries seeds most recent first, skipping ones
    /// too short to count (see `minimumSeedRuntime`); the first full rail wins.
    private func similarRail(seeds: [MediaItem], client: JellyfinClient) async -> LibraryRail? {
        let identity = client.sessionIdentity
        let candidates = seeds
            .filter { HomeCuratedRows.isSubstantialSeed($0) }
            .prefix(HomeCuratedRows.seedAttempts)

        for seed in candidates {
            guard identity == client.sessionIdentity, !Task.isCancelled else { return nil }
            guard let items = try? await client.similarItems(itemId: seed.id, limit: 16),
                  items.count >= HomeCuratedRows.minimumItems
            else { continue }
            guard identity == client.sessionIdentity, !Task.isCancelled else { return nil }
            return LibraryRail(
                id: HomeCuratedRows.ID.becauseYouWatched,
                title: "Because You Watched \(seed.railTitle)",
                items: items
            )
        }
        return nil
    }

    /// Nil when the query fails or returns too few items to look deliberate.
    private func rail(
        id: String,
        title: String,
        client: JellyfinClient,
        includeTypes: [MediaItemType],
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

    /// Top 10 from Seerr's trending and discover lists, matched by TMDB id
    /// to items this Jellyfin user can play.
    private func topTenRails(
        client: JellyfinClient,
        seerr: SeerrClient?,
        enabled: Bool
    ) async -> [LibraryRail] {
        guard enabled, !Task.isCancelled,
              let seerr, seerr.serverURL != nil, seerr.sessionCookie != nil else { return [] }
        async let library = topTenLibraryItems(client: client)
        async let movies = discoveryResults(seerr: seerr, mediaType: .movie)
        async let shows = discoveryResults(seerr: seerr, mediaType: .tv)
        let (libraryResult, movieResults, showResults) = await (library, movies, shows)
        guard let libraryItems = libraryResult, !Task.isCancelled else { return [] }
        let movieItems = TopTenResolver.resolve(
            discoveries: movieResults, library: libraryItems, type: .movie
        )
        let showItems = TopTenResolver.resolve(
            discoveries: showResults, library: libraryItems, type: .series
        )
        return [
            LibraryRail(id: HomeCuratedRows.ID.topMovies, title: "Top 10 Movies", items: movieItems),
            LibraryRail(id: HomeCuratedRows.ID.topShows, title: "Top 10 Shows", items: showItems),
        ].filter { $0.items.count >= HomeCuratedRows.minimumItems }
    }

    /// Reads up to 20,000 library items for the provider-id match. Servers
    /// often cap `Limit`, so it advances by the count actually returned.
    private func topTenLibraryItems(client: JellyfinClient) async -> [MediaItem]? {
        let identity = client.sessionIdentity
        let pageSize = 500
        let maximumItems = 20_000
        var items: [MediaItem] = []
        var startIndex = 0
        var pageCount = 0

        while items.count < maximumItems, pageCount < maximumItems / pageSize {
            guard identity == client.sessionIdentity, !Task.isCancelled else { return nil }
            pageCount += 1
            guard let page = try? await client.items(
                includeTypes: [.movie, .series],
                startIndex: startIndex,
                limit: pageSize,
                fields: "ProviderIds,Overview,Genres,PrimaryImageAspectRatio"
            ) else { return nil }

            guard identity == client.sessionIdentity, !Task.isCancelled else { return nil }
            let fetched = page.items.count
            guard fetched > 0 else { break }
            items.append(contentsOf: page.items.prefix(maximumItems - items.count))
            startIndex += fetched

            if let total = page.totalRecordCount, startIndex >= total { break }
            if page.totalRecordCount == nil, fetched < pageSize { break }
        }
        return items
    }

    private func discoveryResults(seerr: SeerrClient, mediaType: SeerrMediaType) async -> [SeerrDiscoverResult] {
        var candidates: [SeerrDiscoverResult] = []
        for page in 1...3 {
            guard !Task.isCancelled else { return [] }
            guard let result = try? await seerr.trending(page: page, mediaType: mediaType) else { break }
            candidates.append(contentsOf: result.results)
            if result.results.isEmpty || page >= result.totalPages { break }
        }
        for page in 1...3 {
            guard !Task.isCancelled else { return [] }
            guard let result = try? await seerr.discover(mediaType, page: page) else { break }
            candidates.append(contentsOf: result.results)
            if result.results.isEmpty || page >= result.totalPages { break }
        }
        return candidates
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
        cancelDiscoveryTasks()
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
        librarySample = []
        // Or the old account's "Because You Watched" shows on the new one.
        curatedRails = [:]
        collections = []
        errorMessage = nil
    }

    private func cancelDiscoveryTasks() {
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks.removeAll()
    }
}
