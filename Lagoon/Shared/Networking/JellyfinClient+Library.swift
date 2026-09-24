import Foundation

// Library browsing. Uses the user-scoped legacy routes (`Users/{id}/…`),
// which every server from 10.8 onward answers.
extension JellyfinClient {
    /// Extra item fields the UI needs beyond the server's list defaults.
    static let defaultFields = "Overview,Genres,PrimaryImageAspectRatio,ChildCount,Status,OriginalLanguage,ProviderIds"

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

    /// One browse query for the library screens and Home's rows. Unset
    /// filters are left out of the URL.
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
        /// Jellyfin `ItemFilter` names, e.g. `IsUnplayed`.
        filters: [String] = [],
        years: [Int] = [],
        is4K: Bool? = nil,
        minCommunityRating: Double? = nil,
        /// `Continuing`, `Ended`, or `Unreleased`.
        seriesStatus: String? = nil,
        /// Watched flags and resume positions. Turn off for lists of
        /// folders, where they are very expensive (see `collections()`).
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

    /// The genre catalogue for the user's video libraries.
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

    /// The raw item body, saved with a download so its detail page renders
    /// offline. Decode later with `JellyfinClient.decoder`.
    func itemData(id: String) async throws -> Data {
        let userId = try requireUserId()
        return try await getData("Users/\(userId)/Items/\(id)")
    }

    /// Finds a TMDB entry in the user's library by provider id, never by
    /// title or year.
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

    /// Continue Watching. Asks for `MediaSources` because this query feeds
    /// the Top Shelf, whose 4K, HDR and Atmos badges come from the streams.
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
        // The server filters before Limit; this guards servers that still
        // return resumable or watched episodes.
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

    /// Latest can return a lone episode even with GroupItems=true. Resolve
    /// the Series so cards show the show and open its seasons.
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
            // One lookup for all missing series. Keep Latest's order.
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
        // Missing series are dropped. Failures throw so Home keeps the last
        // good rail.
        return orderedIDs.compactMap { seriesByID[$0] }
    }

    /// "More Like This". An empty list hides the rail.
    func similarItems(itemId: String, limit: Int = 12) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Items/\(itemId)/Similar", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        return page.items
    }

    /// Every collection (`BoxSet`) this user can see. Most are empty stubs;
    /// `ChildCount` lets callers drop them (`CollectionShelf.minimumTitles`).
    ///
    /// Keep `EnableUserData=false`: with user data the server walks every
    /// collection's children, 38.6 s against 0.25 s.
    func collections(limit: Int = 200) async throws -> [MediaItem] {
        try await items(
            includeTypes: [.boxSet],
            sortBy: "SortName",
            limit: limit,
            enableUserData: false
        ).items
    }

    /// One collection's titles in release order; `SortName` breaks ties for
    /// undated titles. Not recursive: membership is direct.
    func collectionItems(collectionId: String, limit: Int = 200) async throws -> [MediaItem] {
        try await items(
            parentId: collectionId,
            recursive: false,
            sortBy: "PremiereDate,SortName",
            sortOrder: "Ascending",
            limit: limit
        ).items
    }

    /// The Favorites rail. Movies and series only: the favourite star
    /// targets the series, not episodes.
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

    // MARK: - User data

    /// Marks an item played or unplayed. Marking played is the only way off
    /// Continue Watching; Jellyfin has no "dismiss".
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

    /// What Play on a series starts: the episode in progress, else the next
    /// unwatched. Nil once the series is watched.
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

    /// The next episode for autoplay, or nil at the end of the series.
    ///
    /// Not `Shows/NextUp`: when an episode ends its stop report has not
    /// landed, so NextUp returns the same episode and autoplay loops.
    /// `startItemId` with Limit 2 yields [this, next]; no season filter lets
    /// it cross seasons.
    func episodeAfter(_ episode: MediaItem) async throws -> MediaItem? {
        guard let seriesId = episode.seriesId else { return nil }
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/\(seriesId)/Episodes", query: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "startItemId", value: episode.id),
            URLQueryItem(name: "Limit", value: "2"),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        // If the anchor is not first, the server started from episode 1.
        // Doing nothing beats rolling into it.
        guard page.items.first?.id == episode.id else { return nil }
        return page.items.dropFirst().first
    }
}

// MARK: - Images

nonisolated enum ItemImageKind {
    case primary
    /// Portrait artwork. Episodes use the series poster, not their still.
    case poster
    case backdrop
    case thumb
    /// The title's transparent PNG wordmark.
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
                // An episode's Primary is a screen grab. Use the series even
                // without its tag; the image route does not need one.
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
            // Episode still, then Thumb, then backdrop, then the poster, so
            // a title with no wide artwork still gets a card (as jellyfin-web).
            if item.type == .episode, let primaryTag = item.imageTags?["Primary"] {
                tag = primaryTag
            } else if let thumbTag = item.imageTags?["Thumb"] {
                type = "Thumb"
                tag = thumbTag
            } else {
                return imageURL(for: item, kind: .backdrop, maxWidth: maxWidth)
                    ?? imageURL(for: item, kind: .poster, maxWidth: maxWidth)
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

    /// A user's picture. nil without a tag, since the route 404s and the UI
    /// shows initials. Static because the account picker spans servers.
    nonisolated static func userImageURL(serverURL: URL, userId: String, tag: String?, maxWidth: Int) -> URL? {
        guard let tag,
              var components = URLComponents(
                url: serverURL.appending(path: "Users/\(userId)/Images/Primary"),
                resolvingAgainstBaseURL: false
              ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag),
        ]
        return components.url
    }

    /// Cast headshot. People are items, so it is the item image route.
    func personImageURL(for person: Person, maxWidth: Int) -> URL? {
        guard serverURL != nil, let tag = person.primaryImageTag else { return nil }
        return try? url(path: "Items/\(person.id)/Images/Primary", query: [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag),
        ])
    }
}
