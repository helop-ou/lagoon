import Foundation

/// One paged list of Seerr results, named by where it comes from. Every rail
/// on Discover is one of these, so every rail has a "see all" that shows the
/// same list rather than a nearest-equivalent.
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

    /// Stable across launches, so it can key a rail's identity and its
    /// accessibility identifier.
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
        // Home names its equivalent shelves the same way.
        case .genres(let type): type == .movie ? "Movie Genres" : "Show Genres"
        }
    }
}

/// Turns the server owner's own Discover arrangement into Lagoon's rows.
///
/// `settings/discover` returns bare type numbers in a chosen order, which is
/// exactly what their Jellyseerr web page is built from — so mirroring it
/// means Lagoon agrees with the server instead of inventing a second layout,
/// and re-ordering sliders there re-orders Discover here.
nonisolated enum SeerrDiscoverLayout {
    /// Jellyseerr's own default arrangement, minus the types below. Used when
    /// the server will not say — an older build without the endpoint, a
    /// permission that hides it, or a reply with nothing renderable in it.
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

    /// Types Lagoon has no renderer for return nil and are simply left out,
    /// which is also what keeps a newer Jellyseerr's additions harmless.
    ///
    /// Four are skipped deliberately rather than for want of a renderer:
    /// `recentlyAdded` and `recentRequests` duplicate Home's own rails and
    /// the Requests chip, and `studios`/`networks` are curated brand-logo
    /// shelves in Jellyseerr's web client rather than anything the API
    /// serves.
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
