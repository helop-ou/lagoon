import Foundation

/// One paged list of Seerr results. Every Discover rail is one, so its
/// "see all" shows the same list.
nonisolated enum SeerrCatalogSource: Hashable {
    case trending
    case popular(SeerrMediaType)
    case upcoming(SeerrMediaType)
    case watchlist
    case genre(SeerrMediaType, id: Int, name: String)

    var title: String {
        switch self {
        case .trending: "Trending"
        case .popular(let type): type == .movie ? "Popular Movies" : "Popular Shows"
        case .upcoming(let type): type == .movie ? "Upcoming Movies" : "Upcoming Shows"
        case .watchlist: "Your Watchlist"
        case .genre(_, _, let name): name
        }
    }

    /// Stable across launches; keys rail identity and accessibility ids.
    var id: String {
        switch self {
        case .trending: "trending"
        case .popular(let type): "popular.\(type.rawValue)"
        case .upcoming(let type): "upcoming.\(type.rawValue)"
        case .watchlist: "watchlist"
        case .genre(let type, let id, _): "genre.\(type.rawValue).\(id)"
        }
    }
}

/// A row on Discover. Media rows are posters; genre rows are the browse
/// shelves Jellyseerr draws from `discover/genreslider/*`.
nonisolated enum SeerrDiscoverRow: Hashable, Identifiable {
    case media(SeerrCatalogSource)
    case genres(SeerrMediaType)

    var id: String {
        switch self {
        case .media(let source): source.id
        case .genres(let type): "genres.\(type.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .media(let source): source.title
        case .genres(let type): type == .movie ? "Movie Genres" : "Show Genres"
        }
    }
}

/// Mirrors the server's `settings/discover` slider order, the same list
/// Jellyseerr's web page is built from.
nonisolated enum SeerrDiscoverLayout {
    /// Jellyseerr's default, minus the skipped types. Used when the server
    /// lacks the endpoint, hides it, or returns nothing renderable.
    static let fallback: [SeerrDiscoverRow] = [
        .media(.watchlist),
        .media(.trending),
        .media(.popular(.movie)),
        .genres(.movie),
        .media(.upcoming(.movie)),
        .media(.popular(.tv)),
        .genres(.tv),
        .media(.upcoming(.tv)),
    ]

    static func rows(for sliders: [SeerrDiscoverSlider]) -> [SeerrDiscoverRow] {
        let rows = sliders
            .filter(\.enabled)
            .sorted { $0.order < $1.order }
            .compactMap(row(for:))
        return rows.isEmpty ? fallback : rows
    }

    /// Unknown types return nil, so newer Jellyseerr additions are harmless.
    /// Skipped on purpose: `recentlyAdded` and `recentRequests` duplicate Home
    /// and the Requests chip; `studios`/`networks` are web-client-only logos.
    private static func row(for slider: SeerrDiscoverSlider) -> SeerrDiscoverRow? {
        switch slider.type {
        case .watchlist: .media(.watchlist)
        case .trending: .media(.trending)
        case .popularMovies: .media(.popular(.movie))
        case .popularTV: .media(.popular(.tv))
        case .upcomingMovies: .media(.upcoming(.movie))
        case .upcomingTV: .media(.upcoming(.tv))
        case .movieGenres: .genres(.movie)
        case .tvGenres: .genres(.tv)
        default: nil
        }
    }
}

extension SeerrClient {
    func page(for source: SeerrCatalogSource, page: Int = 1) async throws -> SeerrDiscoverPage {
        switch source {
        case .trending:
            try await trending(page: page)
        case .popular(let type):
            try await discover(type, page: page)
        case .upcoming(let type):
            try await upcoming(type, page: page)
        case .watchlist:
            try await watchlist(page: page)
        case .genre(let type, let id, _):
            try await discover(type, genreID: id, page: page)
        }
    }
}
