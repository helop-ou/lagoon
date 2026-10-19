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
        /// Not in `items`: the hero must never pick a title with no Jellyfin page.
        var externalItems: [JellyfinClient.ExternalSectionItem] = []
        var pluginSection: String?
    }

    /// Plugin sections Lagoon already draws natively. Servers offer several
    /// overlapping ones at once, so showing them would repeat the same titles.
    /// `MyMedia` is the tab bar here.
    static let nativelyCoveredSections: Set<String> = [
        "ContinueWatching", "NextUp", "ContinueWatchingNextUp", "MyMedia",
        "LatestMovies", "LatestShows", "RecentlyAddedMovies", "RecentlyAddedShows",
        "RecentlyAddedInLibrary",
    ]

    var resume: [MediaItem] = []
    var nextUp: [MediaItem] = []
    var favorites: [MediaItem] = []
    /// Rails from the Home Screen Sections plugin, deduped, empties removed.
    var pluginRails: [LibraryRail] = []
    var externalSeerrTitles: [String: ExternalSeerrTitle] = [:]
    private var externalLookups: Set<String> = []
    private var externalLookupCookie: String?
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
    var playlists: [CollectionShelfItem] = []
    /// Titles in Continue Watching or Next Up that continue a collection or
    /// playlist, by title id.
    private(set) var queueContexts: [String: QueueContext] = [:]

    /// Labels for those titles' cards.
    var queueLabels: [String: String] { queueContexts.mapValues(\.label) }

    /// A title that continues a list plays the list from it.
    func playerItem(for item: MediaItem) -> PlayerItem {
        queueContexts[item.id].map { PlayerItem(list: $0.list) } ?? PlayerItem(media: item)
    }
    var isLoading = true
    var errorMessage: String?

    private var hasLoaded = false
    private var loadedAccountID: String?
    private var loadGeneration = 0
    private var isRefreshing = false
    /// Discovery rails load after the primary content; held here so an
    /// account switch can cancel them, and readable so tests can await them.
    private(set) var discoveryTasks: [Task<Void, Never>] = []

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
            let content = try await fetchPrimaryContent(client: client, preferences: homeSectionPreferences)
            guard isCurrent(generation, identity: identity, client: client) else { return }
            apply(content, client: client, identity: identity)
            guard await fillHeroFromLibrarySampleIfEmpty(
                client: client, generation: generation, identity: identity
            ) else { return }
            startDiscoveryLoads(
                client: client, seerr: seerr,
                preferences: homeSectionPreferences, generation: generation
            )
        } catch {
            guard generation == loadGeneration, identity == client.sessionIdentity else { return }
            hasLoaded = false
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn't load your library."
        }
    }

    /// Everything above the fold, fetched before anything is published.
    private struct PrimaryContent {
        /// Nil when the request failed, so the rail keeps its last value.
        let resume: [MediaItem]?
        let nextUp: [MediaItem]
        let favorites: [MediaItem]
        let movieGenres: [MediaGenre]
        let showGenres: [MediaGenre]
        let movieGenreCandidates: [MediaItem]
        let showGenreCandidates: [MediaItem]
        let latestRails: [LibraryRail]
        let pluginRails: [LibraryRail]
        /// Nil when the stored lists could not be read.
        let queues: QueueSnapshot?
    }

    /// The lists the viewer is working through, as Home shows them.
    struct QueueSnapshot {
        var contexts: [String: QueueContext] = [:]
        var upNext: [(title: MediaItem, lastPlayed: String?)] = []
        var seriesLastPlayed: [String: String] = [:]
        /// Lists to forget: finished, emptied or deleted.
        var finished: Set<String> = []
    }

    /// Throws only when the library list fails; that is the one request
    /// Home cannot draw without.
    private func fetchPrimaryContent(
        client: JellyfinClient,
        preferences: HomeSectionPreferenceValues
    ) async throws -> PrimaryContent {
        let libraries = try await client.userViews()
            .filter { LibraryMediaKind.isBrowsable(collectionType: $0.collectionType) }

        async let resumeItems = try? client.resumeItems()
        async let nextUpItems = try? client.nextUp()
        async let queueSnapshot = loadQueueSnapshot(client: client)
        // A failure costs the rail, not the screen.
        async let favoriteItems = try? client.favorites()
        async let movieGenreCatalog = try? client.genres(includeTypes: [.movie])
        async let showGenreCatalog = try? client.genres(includeTypes: [.series])
        async let movieGenreArtworkCandidates = try? client.items(
            includeTypes: [.movie],
            sortBy: "CommunityRating",
            sortOrder: "Descending",
            limit: 300,
            fields: "Genres,CommunityRating"
        )
        async let showGenreArtworkCandidates = try? client.items(
            includeTypes: [.series],
            sortBy: "CommunityRating",
            sortOrder: "Descending",
            limit: 300,
            fields: "Genres,CommunityRating"
        )

        let rails = await loadLatestRails(libraries: libraries, client: client)

        let resolvedResume = await resumeItems
        let resolvedNextUp = await nextUpItems ?? []
        let resolvedFavorites = await favoriteItems ?? []
        let resolvedMovieGenres = await movieGenreCatalog ?? []
        let resolvedShowGenres = await showGenreCatalog ?? []
        let resolvedMovieGenreCandidates = await movieGenreArtworkCandidates?.items ?? []
        let resolvedShowGenreCandidates = await showGenreArtworkCandidates?.items ?? []
        let resolvedPluginRails = await loadPluginRails(client: client, preferences: preferences)
        return PrimaryContent(
            resume: resolvedResume,
            nextUp: resolvedNextUp,
            favorites: resolvedFavorites,
            movieGenres: resolvedMovieGenres,
            showGenres: resolvedShowGenres,
            movieGenreCandidates: resolvedMovieGenreCandidates,
            showGenreCandidates: resolvedShowGenreCandidates,
            latestRails: rails,
            pluginRails: resolvedPluginRails,
            queues: await queueSnapshot
        )
    }

    /// Synchronous, so no suspension splits these writes.
    private func apply(
        _ content: PrimaryContent,
        client: JellyfinClient,
        identity: JellyfinClient.SessionIdentity?
    ) {
        if let resolvedResume = content.resume { resume = resolvedResume }
        nextUp = applyQueues(content.queues, serverNextUp: content.nextUp, client: client)
        favorites = content.favorites
        movieGenreShelf = GenreShelfResolver.resolve(
            catalog: content.movieGenres,
            candidates: content.movieGenreCandidates,
            includeTypes: [.movie]
        )
        showGenreShelf = GenreShelfResolver.resolve(
            catalog: content.showGenres,
            candidates: content.showGenreCandidates,
            includeTypes: [.series]
        )
        latestRails = content.latestRails
        if let resolvedResume = content.resume {
            TopShelfStore.publish(resolvedResume, client: client, identity: identity)
        }
        pluginRails = content.pluginRails
        heroItems = HeroSelection.select(tiers: heroTiers)
    }

    /// With no other hero source, samples the library so a dormant server
    /// still opens on a hero. False when the load went stale meanwhile.
    private func fillHeroFromLibrarySampleIfEmpty(
        client: JellyfinClient,
        generation: Int,
        identity: JellyfinClient.SessionIdentity?
    ) async -> Bool {
        guard heroItems.isEmpty else { return true }
        let sample = (try? await client.items(
            includeTypes: [.movie, .series],
            sortBy: "Random",
            limit: 24
        ))?.items ?? []
        guard isCurrent(generation, identity: identity, client: client) else { return false }
        librarySample = sample
        heroItems = HeroSelection.select(tiers: heroTiers)
        return true
    }

    /// Not awaited: holding `isLoading` for below-the-fold discovery rows
    /// would delay the whole screen. They appear as they resolve.
    private func startDiscoveryLoads(
        client: JellyfinClient,
        seerr: SeerrClient?,
        preferences: HomeSectionPreferenceValues,
        generation: Int
    ) {
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
                    preferences: preferences, generation: generation
                )
            },
            Task { [weak self] in
                guard let self else { return }
                await self.loadCollections(client: client, generation: generation)
            },
            Task { [weak self] in
                guard let self else { return }
                await self.loadPlaylists(client: client, generation: generation)
            },
        ]
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
        async let queueSnapshot = loadQueueSnapshot(client: client)
        let refreshed = await (resume: resumeItems, nextUp: nextUpItems)
        let refreshedQueues = await queueSnapshot
        let refreshedFavorites = await favoriteItems
        guard isCurrent(generation, identity: identity, client: client) else { return }
        if let refreshedResume = refreshed.resume {
            resume = refreshedResume
            TopShelfStore.publish(refreshedResume, client: client, identity: identity)
        }
        if let refreshedNextUp = refreshed.nextUp {
            nextUp = applyQueues(refreshedQueues, serverNextUp: refreshedNextUp, client: client)
        }
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
        async let refreshedPlaylists: Void = loadPlaylists(
            client: client,
            generation: generation
        )
        _ = await (progress, latest, plugin, curated, topTen, refreshedCollections, refreshedPlaylists)
    }

    func refreshPluginRails(
        client: JellyfinClient,
        preferences: HomeSectionPreferenceValues
    ) async {
        guard hasLoaded, !isLoading else { return }
        let generation = loadGeneration
        let identity = client.sessionIdentity
        let rails = await loadPluginRails(client: client, preferences: preferences)
        guard isCurrent(generation, identity: identity, client: client) else { return }
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
            .filter({ LibraryMediaKind.isBrowsable(collectionType: $0.collectionType) }) else { return }
        guard isCurrent(generation, identity: identity, client: client) else { return }
        let refreshed = await loadLatestRails(libraries: libraries, client: client)
        guard isCurrent(generation, identity: identity, client: client) else { return }

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
        let played = await recentlyPlayed(client: client)
        guard isCurrent(generation, identity: identity, client: client) else { return }
        let resolved = await fetchCuratedRails(watchHistory: played, on: Date.now, client: client)
        guard isCurrent(generation, identity: identity, client: client) else { return }
        publishCuratedRails(resolved)
    }

    private func recentlyPlayed(client: JellyfinClient) async -> [MediaItem] {
        (try? await client.items(
            includeTypes: [.movie, .series],
            sortBy: "DatePlayed",
            sortOrder: "Descending",
            limit: 60,
            filters: ["IsPlayed"]
        ))?.items ?? []
    }

    /// Every curated row except Top 10, in display order.
    private func fetchCuratedRails(
        watchHistory played: [MediaItem],
        on today: Date,
        client: JellyfinClient
    ) async -> [LibraryRail] {
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

        return await [
            similar,
            highlyRated,
            fourK,
            genreRail,
            decadeRail,
            unstarted,
            binge,
            surprise,
        ].compactMap(\.self)
    }

    private func publishCuratedRails(_ resolved: [LibraryRail]) {
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
        guard isCurrent(generation, identity: identity, client: client),
              origin == seerr?.serverURL, cookie == seerr?.sessionCookie else { return }
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
        guard isCurrent(generation, identity: identity, client: client) else { return }

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
                        displayOrder: collection.displayOrder,
                        limit: 8
                    )) ?? []
                    return (collection.id, CollectionShelf.artworkSource(from: contents))
                }
            }
            for await (id, artwork) in group {
                borrowed[id] = artwork
            }
        }

        guard isCurrent(generation, identity: identity, client: client) else { return }
        collections = CollectionShelf.shelf(ranked, borrowedArtwork: borrowed)
    }

    /// Reads where the viewer is in each stored list. Each list is fetched
    /// for the server's watch state; one that cannot be fetched is left
    /// alone, one the server no longer has is forgotten.
    private func loadQueueSnapshot(client: JellyfinClient) async -> QueueSnapshot? {
        guard let entries = try? await client.queueProgress() else { return nil }
        guard !entries.isEmpty else { return QueueSnapshot() }
        var contents: [String: Result<[MediaItem], Error>] = [:]
        await withTaskGroup(of: (String, Result<[MediaItem], Error>).self) { group in
            for entry in entries {
                let source = entry.source
                group.addTask {
                    do {
                        let items = switch source.kind {
                        case .playlist:
                            try await client.playlistItems(playlistId: source.id)
                        case .collection:
                            try await client.collectionItems(collectionId: source.id, displayOrder: source.displayOrder)
                        }
                        return (source.id, .success(items))
                    } catch {
                        return (source.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group { contents[id] = result }
        }

        var snapshot = QueueSnapshot()
        for entry in entries {
            switch contents[entry.source.id] {
            case .success(let items)?:
                switch QueueProgressResolver.resolve(entry, items: items) {
                case .inProgress(let context):
                    if snapshot.contexts[context.title.id] == nil { snapshot.contexts[context.title.id] = context }
                case .upNext(let context, let lastPlayed):
                    guard snapshot.contexts[context.title.id] == nil else { continue }
                    snapshot.contexts[context.title.id] = context
                    snapshot.upNext.append((context.title, lastPlayed))
                case .finished:
                    snapshot.finished.insert(entry.source.id)
                }
            case .failure(JellyfinError.server(status: 404, _))?:
                snapshot.finished.insert(entry.source.id)
            default:
                continue
            }
        }
        if !snapshot.upNext.isEmpty {
            snapshot.seriesLastPlayed = (try? await client.seriesLastPlayed()) ?? [:]
        }
        return snapshot
    }

    /// Publishes the lists' cards and returns Next Up with their next titles
    /// mixed in. A failed read keeps the last cards' context.
    private func applyQueues(_ snapshot: QueueSnapshot?, serverNextUp: [MediaItem], client: JellyfinClient) -> [MediaItem] {
        guard let snapshot else { return serverNextUp }
        queueContexts = snapshot.contexts
        if !snapshot.finished.isEmpty {
            Task { try? await client.removeQueueProgress(listIDs: snapshot.finished) }
        }
        return QueueProgressResolver.mergedNextUp(
            server: serverNextUp,
            seriesLastPlayed: snapshot.seriesLastPlayed,
            queued: snapshot.upNext
        )
    }

    /// The Playlists row; see `PlaylistShelf.load`.
    private func loadPlaylists(client: JellyfinClient, generation: Int) async {
        let identity = client.sessionIdentity
        guard let shelf = await PlaylistShelf.load(client: client, limit: CollectionShelf.maximumVisible),
              isCurrent(generation, identity: identity, client: client) else { return }
        playlists = shelf
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
                fields: "ProviderIds,Overview,Genres"
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
                    let contents = await client.homeSectionContents(section)
                    guard !contents.isEmpty else { return nil }
                    return (
                        index: index,
                        rail: LibraryRail(
                            id: HomeRowID.pluginRailID(forSection: section.id),
                            title: section.displayText ?? section.section,
                            items: contents.items,
                            externalItems: contents.externalItems,
                            pluginSection: section.section
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

    func matchExternalTitles(seerr: SeerrClient?) async {
        guard let seerr, seerr.serverURL != nil, let cookie = seerr.sessionCookie else { return }
        if cookie != externalLookupCookie {
            externalLookups = []
            externalLookupCookie = cookie
        }
        let generation = loadGeneration
        for rail in pluginRails {
            let pending = rail.externalItems.filter { externalLookups.insert($0.id).inserted }
            guard !pending.isEmpty else { continue }
            let found = await lookUpExternalTitles(pending, section: rail.pluginSection, seerr: seerr)
            guard generation == loadGeneration, cookie == seerr.sessionCookie else { return }
            externalSeerrTitles.merge(found) { _, new in new }
        }
    }

    private func lookUpExternalTitles(
        _ items: [JellyfinClient.ExternalSectionItem],
        section: String?,
        seerr: SeerrClient
    ) async -> [String: ExternalSeerrTitle] {
        var found: [String: ExternalSeerrTitle] = [:]

        // One list page has twenty backdrops; details cost a request each.
        var unlisted = items.filter { $0.seerrID != nil }
        if let list = ExternalSeerrMatcher.list(forSection: section) {
            for page in 1...3 where !unlisted.isEmpty {
                let listType: SeerrMediaType?
                let results: SeerrDiscoverPage?
                switch list {
                case .trending:
                    listType = nil
                    results = try? await seerr.trending(page: page)
                case .discover(let type):
                    listType = type
                    results = try? await seerr.discover(type, page: page)
                }
                guard let results, !results.results.isEmpty else { break }
                let listed = Dictionary(
                    results.results.compactMap { ExternalSeerrTitle($0, listType: listType) }
                        .map { ("\($0.mediaType.rawValue):\($0.id)", $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                unlisted.removeAll { item in
                    guard let id = item.seerrID, let type = item.seerrType,
                          let title = listed["\(type.rawValue):\(id)"] else { return false }
                    found[item.id] = title
                    return true
                }
                if page >= results.totalPages { break }
            }
        }

        let searched = items.filter { $0.seerrID == nil && $0.seerrType != nil }
        await withTaskGroup(of: (String, ExternalSeerrTitle?).self) { group in
            for item in unlisted + searched {
                group.addTask { (item.id, await ExternalSeerrMatcher.find(item, seerr: seerr)) }
            }
            for await (id, title) in group {
                if let title { found[id] = title }
            }
        }
        return found
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
        externalSeerrTitles = [:]
        externalLookups = []
        externalLookupCookie = nil
        latestRails = []
        heroItems = []
        librarySample = []
        // Or the old account's "Because You Watched" shows on the new one.
        curatedRails = [:]
        collections = []
        playlists = []
        queueContexts = [:]
        errorMessage = nil
    }

    private func cancelDiscoveryTasks() {
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks.removeAll()
    }

    /// A result may land only while its load is the latest, the session it
    /// was fetched for is still signed in, and its task was not cancelled.
    private func isCurrent(
        _ generation: Int,
        identity: JellyfinClient.SessionIdentity?,
        client: JellyfinClient
    ) -> Bool {
        generation == loadGeneration && identity == client.sessionIdentity && !Task.isCancelled
    }
}
