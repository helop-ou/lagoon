import Foundation

/// A Home Screen Sections title from Sonarr, Radarr or Seerr as Seerr knows
/// it: the page its card opens and the backdrop it shows.
nonisolated struct ExternalSeerrTitle: Equatable, Sendable {
    let id: Int
    let mediaType: SeerrMediaType
    let backdropPath: String?

    /// Nil for a person or a result of no known kind. Seerr's per-kind lists
    /// leave `mediaType` out, so the caller says which list it read.
    init?(_ result: SeerrDiscoverResult, listType: SeerrMediaType? = nil) {
        guard let mediaType = result.mediaType ?? listType, mediaType != .person else { return nil }
        id = result.id
        self.mediaType = mediaType
        backdropPath = result.backdropPath
    }

    init(_ details: SeerrMediaDetails, mediaType: SeerrMediaType) {
        self.init(id: details.id, mediaType: mediaType, backdropPath: details.backdropPath)
    }

    init(id: Int, mediaType: SeerrMediaType, backdropPath: String?) {
        self.id = id
        self.mediaType = mediaType
        self.backdropPath = backdropPath
    }
}

nonisolated enum ExternalSeerrMatcher {
    /// The list a Seerr-backed section was read from, as the plugin reads it.
    enum SeerrList: Equatable {
        case trending
        case discover(SeerrMediaType)
    }

    static func list(forSection section: String?) -> SeerrList? {
        switch section {
        case "Discover": .trending
        case "DiscoverMovies": .discover(.movie)
        case "DiscoverTV": .discover(.tv)
        default: nil
        }
    }

    /// Seerr's record of one title: by id for Seerr's own, by search for
    /// Sonarr's and Radarr's. Nil when Seerr has none or cannot be reached.
    @MainActor
    static func find(
        _ item: JellyfinClient.ExternalSectionItem,
        seerr: SeerrClient
    ) async -> ExternalSeerrTitle? {
        if let id = item.seerrID, let type = item.seerrType {
            let details = try? await seerr.details(id: id, mediaType: type)
            return details.map { ExternalSeerrTitle($0, mediaType: type) }
        }
        guard item.seerrType != nil else { return nil }
        let results = (try? await seerr.search(query: item.title))?.results ?? []
        return match(item, in: results)
    }

    /// A Sonarr or Radarr title among Seerr's search results: the same kind
    /// and the same title once case, accents and punctuation are set aside,
    /// and for a movie with a year, that year, which tells remakes apart.
    /// Seerr ranks by popularity, so the first such result wins.
    static func match(
        _ item: JellyfinClient.ExternalSectionItem,
        in results: [SeerrDiscoverResult]
    ) -> ExternalSeerrTitle? {
        guard item.seerrID == nil, let type = item.seerrType else { return nil }
        let wanted = normalized(item.title)
        guard !wanted.isEmpty else { return nil }
        let match = results.first { result in
            guard result.mediaType == type else { return false }
            if let year = item.year, result.year.flatMap(Int.init) != year { return false }
            return [result.title, result.name, result.originalTitle, result.originalName]
                .contains { $0.map(normalized) == wanted }
        }
        return match.flatMap { ExternalSeerrTitle($0) }
    }

    static func normalized(_ title: String) -> String {
        String(String.UnicodeScalarView(
            title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .unicodeScalars
                .filter(CharacterSet.alphanumerics.contains)
        ))
    }
}
