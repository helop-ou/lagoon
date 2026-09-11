import Foundation

/// The curated Home rows and the rotation that keeps two of them fresh
/// (HEL-120).
///
/// Home's order follows the one HEL-114 settled on for Discover, because the
/// same thing was wrong with both screens: browse shelves sitting in the
/// middle of content, and movies and shows interleaved so the screen never
/// settles on a subject. The order is personal, then new, then a whole movie
/// block, then a whole show block, then anything — and each block closes with
/// its own genre shelf, which is the "none of these, go look yourself" exit.
nonisolated enum HomeCuratedRows {
    /// Identifiers for Settings, Home Rows. Stable strings rather than an
    /// enum's `rawValue`, because they are persisted per account and renaming
    /// a case must not silently re-enable a row someone hid.
    enum ID {
        static let becauseYouWatched = "lagoon.becauseYouWatched"
        static let highlyRated = "lagoon.highlyRated"
        static let inFourK = "lagoon.inFourK"
        static let genreSpotlight = "lagoon.genreSpotlight"
        static let decadeSpotlight = "lagoon.decadeSpotlight"
        static let unstartedSeries = "lagoon.unstartedSeries"
        static let readyToBinge = "lagoon.readyToBinge"
        static let surpriseMe = "lagoon.surpriseMe"
    }

    /// Below this a rail is a stub rather than a row, and hides itself. Three
    /// posters on a 16:9 screen reads as "we found almost nothing", which is
    /// worse than the row not being there.
    static let minimumItems = 4

    /// What "Highly Rated" is willing to call highly rated. Deliberately not
    /// 8: on a personal library that empties the row on most servers.
    static let minimumCommunityRating = 7.5

    /// The shortest thing "Because You Watched" will name itself after.
    ///
    /// A self-hosted library is full of things that are played but are not
    /// viewing: Dolby and DTS demo reels, test patterns, trailers, home
    /// video. The first run against a real library seeded the row from
    /// *Dolby: Core Universe* and recommended five unrelated films off the
    /// back of it. Fifteen minutes clears that out while keeping a
    /// twenty-two minute comedy, which is the shortest thing anyone actually
    /// sits down to.
    static let minimumSeedRuntime: Double = 15 * 60

    /// How many recently played titles to try before giving up on the row. A
    /// seed can be perfectly real and still have no similar items on a small
    /// library, and one dud should not cost the row.
    static let seedAttempts = 4

    /// Whether a played title is worth naming a recommendation row after.
    ///
    /// An unknown runtime passes: servers do not always report one, and
    /// refusing every title with a gap in its metadata would be a harsher
    /// filter than the one intended.
    static func isSubstantialSeed(_ item: MediaItem) -> Bool {
        guard let ticks = item.runTimeTicks else { return true }
        return Ticks.seconds(ticks) >= minimumSeedRuntime
    }
}

/// Picks the genre and the decade that Home spotlights today.
///
/// **Seeded by the day, not by the launch.** Re-rolling on every appearance
/// makes Home feel jittery rather than curated — you glance away, look back,
/// and the screen has rearranged itself. A day is long enough to feel chosen
/// and short enough to stay alive.
nonisolated enum HomeRotation {
    /// Days since the epoch, in the viewer's own timezone so the row turns
    /// over at their midnight rather than at UTC's.
    static func daySeed(for date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int(start.timeIntervalSince1970 / 86_400)
    }

    /// The genre to spotlight, chosen from the viewer's own most-watched
    /// first. "More Horror" earns its place where a fixed "Horror" out of
    /// nowhere does not, so a ranked list is the input and the rotation only
    /// decides which of their favourites gets today.
    ///
    /// Ranked order is preserved, so this rotates through what they actually
    /// watch rather than sampling the whole library.
    static func genre(
        rankedByWatchHistory genres: [String],
        for date: Date,
        calendar: Calendar = .current
    ) -> String? {
        guard !genres.isEmpty else { return nil }
        // Only the top handful are theirs in any meaningful sense; below that
        // it is one film they finished once.
        let candidates = Array(genres.prefix(5))
        return candidates[abs(daySeed(for: date, calendar: calendar)) % candidates.count]
    }

    /// The decade to spotlight, as its first year. Stops at the 1970s because
    /// a personal library thins out fast before then, and excludes the
    /// current decade, which "Recently Added" already covers.
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

    /// "Movies from the 1990s". Spelled in full rather than as "90s", which
    /// is ambiguous once a library holds anything from the 1890s or 2090s.
    static func decadeTitle(startingIn year: Int) -> String {
        "Movies from the \(year)s"
    }

    /// The genres this viewer actually watches, most first.
    ///
    /// Counts genres across their played items rather than the whole library,
    /// so a shelf full of unwatched documentaries does not decide what Home
    /// recommends. Ties break on the genre name so the ranking is stable
    /// between loads and the rotation does not jump.
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
