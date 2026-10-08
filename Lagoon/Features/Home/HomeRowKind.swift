import Foundation

/// What Home draws for a row id. `HomeView` switches on this rather than on
/// the id, so every native row it can draw is listed in one table that tests
/// hold against the rows Settings offers.
nonisolated enum HomeRowKind: Equatable {
    case continueWatching
    case nextUp
    case favorites
    case recentlyAddedMovies
    case recentlyAddedShows
    case movieGenres
    case showGenres
    case collections
    case topTen
    /// A rail `HomeViewModel` publishes into `curatedRails` under its id.
    case curated
    case plugin(section: String)

    /// Every native row Home draws, by id.
    static let native: [String: HomeRowKind] = [
        HomeRowID.continueWatching: .continueWatching,
        HomeRowID.nextUp: .nextUp,
        HomeRowID.favorites: .favorites,
        HomeRowID.recentlyAddedMovies: .recentlyAddedMovies,
        HomeRowID.recentlyAddedShows: .recentlyAddedShows,
        HomeRowID.movieGenres: .movieGenres,
        HomeRowID.showGenres: .showGenres,
        CollectionShelf.rowID: .collections,
        HomeCuratedRows.ID.topMovies: .topTen,
        HomeCuratedRows.ID.topShows: .topTen,
        HomeCuratedRows.ID.becauseYouWatched: .curated,
        HomeCuratedRows.ID.highlyRated: .curated,
        HomeCuratedRows.ID.inFourK: .curated,
        HomeCuratedRows.ID.genreSpotlight: .curated,
        HomeCuratedRows.ID.decadeSpotlight: .curated,
        HomeCuratedRows.ID.unstartedSeries: .curated,
        HomeCuratedRows.ID.readyToBinge: .curated,
        HomeCuratedRows.ID.surpriseMe: .curated,
    ]

    /// Nil for a native id this build does not draw.
    init?(id: String) {
        if let kind = Self.native[id] {
            self = kind
        } else if HomeRowID.isNative(id) {
            return nil
        } else {
            self = .plugin(section: id)
        }
    }
}
