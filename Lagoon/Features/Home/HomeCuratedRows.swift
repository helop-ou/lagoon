import Foundation

/// The curated Home rows and the rotation that keeps two of them fresh.
///
/// Order: personal, then new, then a movie block, then a show block (each
/// ending with its genre shelf), then mixed rows.
nonisolated enum HomeCuratedRows {
    /// Persisted per account; renaming one would re-enable a hidden row.
    enum ID {
        static let becauseYouWatched = "lagoon.becauseYouWatched"
        static let highlyRated = "lagoon.highlyRated"
        static let topMovies = "lagoon.topMovies"
        static let inFourK = "lagoon.inFourK"
        static let genreSpotlight = "lagoon.genreSpotlight"
        static let decadeSpotlight = "lagoon.decadeSpotlight"
        static let unstartedSeries = "lagoon.unstartedSeries"
        static let topShows = "lagoon.topShows"
        static let readyToBinge = "lagoon.readyToBinge"
        static let surpriseMe = "lagoon.surpriseMe"
    }

    /// Fewer items than this looks like a stub, so the row hides.
    static let minimumItems = 4

    /// Not 8: that empties the row on most personal libraries.
    static let minimumCommunityRating = 7.5

    /// Seconds. Filters out demo reels, trailers and test patterns while
    /// keeping a 22-minute sitcom episode.
    static let minimumSeedRuntime: Double = 15 * 60

    /// Recent titles to try; a real seed can still have no similar items.
    static let seedAttempts = 4

    /// An unknown runtime passes; servers do not always report one.
    static func isSubstantialSeed(_ item: MediaItem) -> Bool {
        guard let ticks = item.runTimeTicks else { return true }
        return Ticks.seconds(ticks) >= minimumSeedRuntime
    }
}

/// Matches Seerr's ranked results to playable Jellyfin items by TMDB id.
/// Pure, so it is testable without a network.
nonisolated enum TopTenResolver {
    static func resolve(
        discoveries: [SeerrDiscoverResult],
        library: [MediaItem],
        type: MediaItemType
    ) -> [MediaItem] {
        let mediaType: SeerrMediaType
        switch type {
        case .movie: mediaType = .movie
        case .series: mediaType = .tv
        default: return []
        }
        let byTMDB = Dictionary(
            library
                .filter { $0.type == type }
                .compactMap { item -> (String, MediaItem)? in
                    guard let provider = item.providerIds?.first(where: {
                        $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame
                    }), !provider.value.isEmpty else { return nil }
                    return (provider.value, item)
                },
            uniquingKeysWith: { current, _ in current }
        )

        var seen = Set<Int>()
        let matches: [MediaItem] = discoveries.compactMap { result in
            // Discover may omit mediaType. Movie and TV TMDB ids overlap, so
            // a conflicting type must never match.
            guard result.mediaType == nil || result.mediaType == mediaType,
                  seen.insert(result.id).inserted else { return nil }
            return byTMDB[String(result.id)]
        }.prefix(10).map { $0 }
        return matches.count >= HomeCuratedRows.minimumItems ? matches : []
    }
}

/// Picks the genre and decade Home spotlights today. Seeded by the day, not
/// the launch, so Home does not reshuffle every time it appears.
nonisolated enum HomeRotation {
    /// Days since the epoch in the local timezone, so rows turn over at
    /// local midnight.
    static func daySeed(for date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int(start.timeIntervalSince1970 / 86_400)
    }

    /// Rotates daily through the viewer's most-watched genres.
    static func genre(
        rankedByWatchHistory genres: [String],
        for date: Date,
        calendar: Calendar = .current
    ) -> String? {
        guard !genres.isEmpty else { return nil }
        // Below the top five it is one film they finished once.
        let candidates = Array(genres.prefix(5))
        return candidates[abs(daySeed(for: date, calendar: calendar)) % candidates.count]
    }

    /// First year of the decade. From the 1970s (libraries thin out before)
    /// up to but not including the current decade (Recently Added covers it).
    static func decade(
        for date: Date,
        calendar: Calendar = .current
    ) -> Int? {
        let thisYear = calendar.component(.year, from: date)
        let currentDecade = thisYear - (thisYear % 10)
        let candidates = stride(from: 1970, to: currentDecade, by: 10).map { $0 }
        guard !candidates.isEmpty else { return nil }
        return candidates[abs(daySeed(for: date, calendar: calendar)) % candidates.count]
    }

    static func decadeTitle(startingIn year: Int) -> String {
        "Movies from the \(year)s"
    }

    /// Genres across played items, most first; ties break on name so the
    /// rotation is stable between loads.
    static func rankGenres(byWatchHistory items: [MediaItem]) -> [String] {
        var counts: [String: Int] = [:]
        for genre in items.flatMap({ $0.genres ?? [] }) {
            counts[genre, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }
}
