import Foundation

// Library browsing. Uses the user-scoped legacy routes (`Users/{id}/…`),
// which every server from 10.8 onward answers.
extension JellyfinClient {
    /// Extra item fields the UI needs beyond the server's list defaults.
    static let defaultFields = "Overview,Genres,Taglines,PrimaryImageAspectRatio,ChildCount,Status"

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
        searchTerm: String? = nil,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> ItemsPage {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ]
        if let parentId {
            query.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        if !includeTypes.isEmpty {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.map(\.rawValue).joined(separator: ",")))
        }
        if let searchTerm {
            query.append(URLQueryItem(name: "SearchTerm", value: searchTerm))
        }
        return try await get("Users/\(userId)/Items", query: query)
    }

    func item(id: String) async throws -> MediaItem {
        let userId = try requireUserId()
        return try await get("Users/\(userId)/Items/\(id)")
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

    func seasons(seriesId: String) async throws -> [MediaItem] {
        let userId = try requireUserId()
        let page: ItemsPage = try await get("Shows/\(seriesId)/Seasons", query: [
            URLQueryItem(name: "UserId", value: userId),
        ])
        return page.items
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
}

// MARK: - Images

nonisolated enum ItemImageKind {
    case primary
    case backdrop
    case thumb
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
