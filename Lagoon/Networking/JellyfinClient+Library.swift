import Foundation

// Library browsing. Uses the user-scoped legacy routes (`Users/{id}/…`),
// which every server from 10.8 onward answers.
extension JellyfinClient {
    /// Extra item fields the UI needs beyond the server's list defaults.
    static let defaultFields = "Overview,Genres,Taglines,PrimaryImageAspectRatio,ChildCount,Status,OriginalLanguage,ProviderIds"

    func userViews() async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Users/\(userId)/Views")
        return page.items
    }

    func libraryItems(_ selection: LibrarySelection, startIndex: Int, limit: Int) async throws -> ItemsPage {
        try await items(
            parentId: selection.libraryID,
            includeTypes: selection.kind.includeTypes,
            sortBy: selection.sort.sortBy,
            sortOrder: selection.sort.sortOrder,
            genres: selection.genre.map { [$0] } ?? [],
            startIndex: startIndex,
            limit: limit,
            filters: selection.filters,
            years: selection.decade?.years ?? [],
            is4K: selection.kind == .movies && selection.only4K ? true : nil
        )
    }

    func libraryYears(_ scope: LibraryYearScope) async throws -> [Int] {
        var query = [
            URLQueryItem(name: "UserId", value: try requireUserId()),
            URLQueryItem(name: "IncludeItemTypes", value: scope.kind.includeTypes.map(\.rawValue).joined(separator: ",")),
        ]
        if let libraryID = scope.libraryID {
            query.append(URLQueryItem(name: "ParentId", value: libraryID))
        }
        // Filters2 has no Years field. The legacy filters endpoint returns
        // all production years, recursively scoped to the user and library.
        let filters: LibraryYearFilters = try await get("Items/Filters", query: query)
        return filters.years
    }

    /// One browse query, shared by the library screens and by Home's curated
    /// rows (HEL-120). The filter arguments are all optional and all omitted
    /// from the URL when unset, so a caller pays only for what it asks for.
    func items(
        parentId: String? = nil,
        includeTypes: [MediaItemType] = [],
        recursive: Bool = true,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        genres: [String] = [],
        searchTerm: String? = nil,
        startIndex: Int = 0,
        limit: Int = 100,
        fields: String? = nil,
        /// `ItemFilter` values, e.g. `IsUnplayed`. Spelled by the caller
        /// because Jellyfin's own names are the clearest thing to read here.
        filters: [String] = [],
        years: [Int] = [],
        is4K: Bool? = nil,
        minCommunityRating: Double? = nil,
        /// `Continuing`, `Ended`, or `Unreleased`.
        seriesStatus: String? = nil,
        /// Watched flags and resume positions. Leave them on for anything a
        /// card draws progress for; turn them off for a list of *folders*,
        /// where they are ruinously expensive — see `collections()`.
        enableUserData: Bool = true
    ) async throws -> ItemsPage {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: fields ?? Self.defaultFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ]
        if !filters.isEmpty {
            query.append(URLQueryItem(name: "Filters", value: filters.joined(separator: ",")))
        }
        if !years.isEmpty {
            query.append(URLQueryItem(name: "Years", value: years.map(String.init).joined(separator: ",")))
        }
        if let is4K {
            query.append(URLQueryItem(name: "Is4K", value: is4K ? "true" : "false"))
        }
        if let minCommunityRating {
            query.append(URLQueryItem(name: "MinCommunityRating", value: String(minCommunityRating)))
        }
        if let seriesStatus {
            query.append(URLQueryItem(name: "SeriesStatus", value: seriesStatus))
        }
        if !enableUserData {
            query.append(URLQueryItem(name: "EnableUserData", value: "false"))
        }
        if let parentId {
            query.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        if !includeTypes.isEmpty {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.map(\.rawValue).joined(separator: ",")))
        }
        if !genres.isEmpty {
            query.append(URLQueryItem(name: "Genres", value: genres.joined(separator: "|")))
        }
        if let searchTerm {
            query.append(URLQueryItem(name: "SearchTerm", value: searchTerm))
        }
        return try await get("Users/\(userId)/Items", query: query)
    }

    /// The native genre catalogue for the signed-in user's playable video
    /// libraries. One catalogue request plus one ranked artwork request is
    /// deliberately cheaper than fetching a representative for every genre.
    func genres(includeTypes: [MediaItemType] = [.movie, .series]) async throws -> [MediaGenre] {
        let userId = try requireUserId()
        let page: GenresPage = try await get("Genres", query: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
            URLQueryItem(name: "Limit", value: "100"),
        ])
        return page.items
    }

    func item(id: String) async throws -> MediaItem {
        let userId = try requireUserId()
        return try await get("Users/\(userId)/Items/\(id)")
    }

    /// Resolves a Seerr/TMDB catalogue entry back into this user's Jellyfin
    /// library without guessing from title or year.
    func item(tmdbID: Int, mediaType: SeerrMediaType) async throws -> MediaItem? {
        let userId = try requireUserId()
        let includeType = mediaType == .tv ? MediaItemType.series : .movie
        let page: ItemsPage = try await get("Users/\(userId)/Items", query: [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "AnyProviderIdEquals", value: "Tmdb.\(tmdbID)"),
            URLQueryItem(name: "IncludeItemTypes", value: includeType.rawValue),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ])
        let expectedID = String(tmdbID)
        return page.items.first { item in
            item.providerIds?.first(where: {
                $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame
            })?.value == expectedID
        }
    }

    /// Continue Watching. `MediaSources` rides along because this is the one
    /// query that feeds the Top Shelf, and the carousel shows 4K, HDR and
    /// Atmos badges from the streams (HEL-119). Asking here costs one larger
    /// response on a query that already runs; the alternative was a second
    /// round trip inside `TopShelfStore.publish` for the same facts.
    func resumeItems(limit: Int = 12) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Users/\(userId)/Items/Resume", query: [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "MediaTypes", value: "Video"),
            URLQueryItem(name: "Fields", value: "\(Self.defaultFields),MediaSources"),
        ])
        return page.items
    }

    /// Home's unstarted episodes. A series with an episode in progress stays
    /// in Continue Watching; excluding it must not skip ahead in that series.
    func nextUp(limit: Int = 12) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/NextUp", query: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
            URLQueryItem(name: "EnableResumable", value: "false"),
            URLQueryItem(name: "EnableRewatching", value: "false"),
        ])
        // Filter on the server before Limit, with a defensive check for
        // servers that still return resumable or already watched episodes.
        return page.items.filter {
            ($0.userData?.playbackPositionTicks ?? 0) <= 0
                && ($0.userData?.playedPercentage ?? 0) <= 0
                && $0.userData?.played != true
        }
    }

    /// Note: unlike every other list endpoint, Latest returns a bare array.
    func latest(parentId: String, limit: Int = 16) async throws -> [MediaItem] {
        let userId = try requireUserId()
        return try await get("Users/\(userId)/Items/Latest", query: [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
    }

    /// Latest groups containing just one episode can be returned as Episodes,
    /// even with Jellyfin's default GroupItems=true. Resolve real Series DTOs
    /// so cards use the show's artwork and open its seasons, not one episode.
    func latestSeries(parentId: String, limit: Int = 16) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let serverURL = self.serverURL
        let accessToken = self.accessToken
        func checkSession() throws {
            try Task.checkCancellation()
            guard self.userId == userId, self.serverURL == serverURL,
                  self.accessToken == accessToken else { throw CancellationError() }
        }

        try checkSession()
        let recent = try await latest(parentId: parentId, limit: limit)
        try checkSession()
        var seriesByID = Dictionary(
            recent.filter { $0.type == .series }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let orderedIDs = recent.compactMap { item -> String? in
            let id: String?
            switch item.type {
            case .series: id = item.id
            case .episode, .season: id = item.seriesId
            default: id = nil
            }
            guard let id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        let missingIDs = orderedIDs.filter { seriesByID[$0] == nil }
        if !missingIDs.isEmpty {
            // One bounded lookup, not one request per episode. Keep Latest's
            // child-addition order rather than sorting by the series' age.
            let page: ItemsPage = try await get("Users/\(userId)/Items", query: [
                URLQueryItem(name: "Ids", value: missingIDs.joined(separator: ",")),
                URLQueryItem(name: "IncludeItemTypes", value: MediaItemType.series.rawValue),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Limit", value: String(missingIDs.count)),
                URLQueryItem(name: "Fields", value: Self.defaultFields),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
            ])
            try checkSession()
            for series in page.items where series.type == .series && seriesByID[series.id] == nil {
                seriesByID[series.id] = series
            }
        }
        // Removed/inaccessible parents are omitted. Request failures throw so
        // Home's existing refresh fallback keeps the last good rail instead.
        return orderedIDs.compactMap { seriesByID[$0] }
    }

    /// "More Like This" on the detail page (HEL-46). The server does the
    /// picking; an empty list just hides the rail.
    func similarItems(itemId: String, limit: Int = 12) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Items/\(itemId)/Similar", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        return page.items
    }

    /// Every collection (a Jellyfin `BoxSet`) this user can see.
    ///
    /// **Expect most of them to be empty.** A metadata scrape creates a
    /// collection for a film's entire franchise whether or not the library
    /// holds the rest of it, so the reference server answers this with 173
    /// collections of which 35 contain anything at all and 18 contain more
    /// than one title. `ChildCount` rides in `defaultFields` precisely so a
    /// caller can drop the stubs without a request per collection — see
    /// `CollectionShelf.minimumTitles`.
    ///
    /// **`EnableUserData=false` is what makes this query usable, not a
    /// micro-optimisation.** A collection's `UserData` carries
    /// `UnplayedItemCount`, which the server can only answer by walking that
    /// collection's children — about a quarter-second each. Measured against
    /// the reference server's 173 collections: **38.6 s with user data and
    /// 0.25 s without**, and the cost tracks the number of collections rather
    /// than anything the query asks for (dropping `Fields`, naming the
    /// Collections library as `ParentId`, and asking for 20 instead of 200
    /// each changed nothing). Nothing here needs the flags: the row draws a
    /// name and a count, and the contents of one collection are a separate,
    /// cheap request that keeps its user data.
    func collections(limit: Int = 200) async throws -> [MediaItem] {
        try await items(
            includeTypes: [.boxSet],
            sortBy: "SortName",
            limit: limit,
            enableUserData: false
        ).items
    }

    /// What is inside one collection, in release order.
    ///
    /// Release order is the order a franchise reads in and `SortName` is not:
    /// alphabetically *Aliens vs Predator: Requiem* opens the AVP collection
    /// and *Alien 3* precedes *Aliens*. `PremiereDate` fixes both, with
    /// `SortName` behind it for the titles a server has no date for.
    ///
    /// Not recursive and not paged: collection membership is direct, and a
    /// franchise that needs a second page of two hundred does not exist.
    func collectionItems(collectionId: String, limit: Int = 200) async throws -> [MediaItem] {
        try await items(
            parentId: collectionId,
            recursive: false,
            sortBy: "PremiereDate,SortName",
            sortOrder: "Ascending",
            limit: limit
        ).items
    }

    /// The Favorites rail (HEL-40). `Filters=IsFavorite` does the picking
    /// server-side. Restricted to movies and series because favouriting is
    /// a show-level gesture — `ItemActionRow`'s star deliberately targets
    /// the series, so a rail full of individual episodes would be noise.
    func favorites(limit: Int = 16) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Users/\(userId)/Items", query: [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ])
        return page.items
    }

    // MARK: - User data (HEL-40)

    /// Marks an item played, or clears it. Clearing also puts a finished item
    /// *back* on Continue Watching, and marking played is how an item leaves
    /// it — Jellyfin has no separate "dismiss" for the resume rail.
    ///
    /// Both flags are POST-to-set, DELETE-to-clear on the same path, which is
    /// why this reads as a toggle rather than a pair of verbs.
    func setPlayed(_ played: Bool, itemId: String) async throws {
        let userId = try requireUserId()
        let path = "Users/\(userId)/PlayedItems/\(itemId)"
        if played {
            try await postVoid(path)
        } else {
            try await deleteVoid(path)
        }
    }

    func setFavorite(_ favorite: Bool, itemId: String) async throws {
        let userId = try requireUserId()
        let path = "Users/\(userId)/FavoriteItems/\(itemId)"
        if favorite {
            try await postVoid(path)
        } else {
            try await deleteVoid(path)
        }
    }

    func seasons(seriesId: String) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/\(seriesId)/Seasons", query: [
            URLQueryItem(name: "UserId", value: userId),
        ])
        return page.items
    }

    /// The episode a Play press on a series page should start: the one in
    /// progress if there is one, otherwise the next unwatched. Nil once the
    /// series is fully watched — `Shows/NextUp` simply returns nothing.
    func nextUpEpisode(seriesId: String) async throws -> MediaItem? {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/NextUp", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "seriesId", value: seriesId),
            URLQueryItem(name: "EnableResumable", value: "true"),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        return page.items.first
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        if let seasonId {
            query.append(URLQueryItem(name: "SeasonId", value: seasonId))
        }
        let page: ItemsPage = try await get("Shows/\(seriesId)/Episodes", query: query)
        return page.items
    }

    /// The episode that follows this one in its series, or nil once the run
    /// is over — what autoplay rolls into (HEL-66).
    ///
    /// Deliberately *not* `Shows/NextUp`. That endpoint returns the episode
    /// in progress when there is one (`enableResumable` defaults to true,
    /// per the server's own OpenAPI document), and at the moment an episode
    /// finishes its stop report has not landed yet — so NextUp hands back
    /// the episode that just ended and autoplay loops on it forever.
    ///
    /// `startItemId` runs the series list forward to a given episode, so
    /// asking for two from there yields [this, next]. Naming no season is
    /// what carries a binge across a season boundary.
    func episodeAfter(_ episode: MediaItem) async throws -> MediaItem? {
        guard let seriesId = episode.seriesId else { return nil }
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/\(seriesId)/Episodes", query: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "startItemId", value: episode.id),
            URLQueryItem(name: "Limit", value: "2"),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        // A first item that isn't the anchor means the server never found it
        // and started from the top of the series instead. Rolling into
        // episode 1 would be far worse than doing nothing.
        guard page.items.first?.id == episode.id else { return nil }
        return page.items.dropFirst().first
    }
}

// MARK: - Images

nonisolated enum ItemImageKind {
    case primary
    /// Portrait artwork for metadata surfaces. Episodes deliberately inherit
    /// the series Primary image instead of using their landscape still.
    case poster
    case backdrop
    case thumb
    /// The title's own artwork — a transparent PNG wordmark. Jellyfin has
    /// one for practically every film (HEL-46 reference shot).
    case logo
}

extension JellyfinClient {
    /// Builds an image URL for an item, falling back through parent artwork
    /// the way the official clients do (episode → series poster, etc.).
    func imageURL(for item: MediaItem, kind: ItemImageKind, maxWidth: Int) -> URL? {
        guard serverURL != nil else { return nil }

        var itemId = item.id
        var type = "Primary"
        var tag: String?

        switch kind {
        case .primary:
            if let primaryTag = item.imageTags?["Primary"] {
                tag = primaryTag
            } else if let seriesId = item.seriesId, let seriesTag = item.seriesPrimaryImageTag {
                itemId = seriesId
                tag = seriesTag
            } else {
                return nil
            }
        case .poster:
            if item.type == .episode, let seriesId = item.seriesId {
                // Jellyfin stores an episode screen grab in Primary. The
                // player's portrait slot represents the title, so resolve
                // through the series even when the list response omitted its
                // image tag; the image endpoint does not require that tag.
                itemId = seriesId
                tag = item.seriesPrimaryImageTag
            } else if let primaryTag = item.imageTags?["Primary"] {
                tag = primaryTag
            } else if let seriesId = item.seriesId {
                itemId = seriesId
                tag = item.seriesPrimaryImageTag
            } else {
                return nil
            }
        case .backdrop:
            type = "Backdrop/0"
            if let backdropTag = item.backdropImageTags?.first {
                tag = backdropTag
            } else if let parentId = item.parentBackdropItemId, let parentTag = item.parentBackdropImageTags?.first {
                itemId = parentId
                tag = parentTag
            } else {
                return nil
            }
        case .logo:
            // Episodes and seasons inherit the series' wordmark.
            if let logoTag = item.imageTags?["Logo"] {
                type = "Logo"
                tag = logoTag
            } else {
                return nil
            }
        case .thumb:
            // Episode stills live in the Primary slot; prefer them, then backdrops.
            if item.type == .episode, let primaryTag = item.imageTags?["Primary"] {
                tag = primaryTag
            } else if let thumbTag = item.imageTags?["Thumb"] {
                type = "Thumb"
                tag = thumbTag
            } else {
                return imageURL(for: item, kind: .backdrop, maxWidth: maxWidth)
            }
        }

        var query = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let tag {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        return try? url(path: "Items/\(itemId)/Images/\(type)", query: query)
    }

    /// Cast headshot. People are items too, so this is the same image route
    /// with the credit's own id (HEL-46).
    func personImageURL(for person: Person, maxWidth: Int) -> URL? {
        guard serverURL != nil, let tag = person.primaryImageTag else { return nil }
        return try? url(path: "Items/\(person.id)/Images/Primary", query: [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag),
        ])
    }
}
