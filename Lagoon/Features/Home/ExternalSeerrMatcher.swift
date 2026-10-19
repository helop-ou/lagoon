import Foundation

nonisolated struct ExternalSeerrTitle: Equatable, Sendable {
    let id: Int
    let mediaType: SeerrMediaType
    let backdropPath: String?

    /// Seerr's per-kind lists leave `mediaType` out.
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

    static func route(
        for item: JellyfinClient.ExternalSectionItem,
        seerrTitle: ExternalSeerrTitle?,
        isSignedIn: Bool
    ) -> SeerrNavigationRoute? {
        if let seerrTitle {
            return .media(id: seerrTitle.id, type: seerrTitle.mediaType)
        }
        guard !isSignedIn, item.seerrType != nil else { return nil }
        return .signIn(then: item)
    }

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

    /// Seerr ranks by popularity, so the first match wins.
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
