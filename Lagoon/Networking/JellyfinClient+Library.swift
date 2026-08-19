import Foundation

// Library browsing. Uses the user-scoped legacy routes (`Users/{id}/…`),
// which every server from 10.8 onward answers.
extension JellyfinClient {
    /// Extra item fields the UI needs beyond the server's list defaults.
    static let defaultFields = "Overview,Genres,Taglines,PrimaryImageAspectRatio,ChildCount,Status,OriginalLanguage"

    func userViews() async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Users/\(userId)/Views")
        return page.items
    }

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
        fields: String? = nil
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
            URLQueryItem(name: "AnyProviderIdEquals", value: "tmdb.\(tmdbID)"),
            URLQueryItem(name: "IncludeItemTypes", value: includeType.rawValue),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ])
        return page.items.first
    }

    func resumeItems(limit: Int = 12) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Users/\(userId)/Items/Resume", query: [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "MediaTypes", value: "Video"),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        return page.items
    }

    func nextUp(limit: Int = 12) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/NextUp", query: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
        ])
        return page.items
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
