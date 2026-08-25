import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr discover layout")
struct SeerrDiscoverLayoutTests {
    /// The shape `settings/discover` actually returns: built-ins carry a type
    /// number and an order, and `title` is null because the client is expected
    /// to name them.
    private func sliders(_ entries: [(type: Int, order: Int, enabled: Bool)]) throws -> [SeerrDiscoverSlider] {
        let json = entries.enumerated().map { index, entry in
            """
            {"id":\(index + 1),"type":\(entry.type),"order":\(entry.order),\
            "isBuiltIn":true,"enabled":\(entry.enabled),"title":null,"data":null}
            """
        }.joined(separator: ",")
        return try JSONDecoder().decode([SeerrDiscoverSlider].self, from: Data("[\(json)]".utf8))
    }

    /// Exactly what the live Jellyseerr 3.4.1 returns out of the box: twelve
    /// built-ins, all enabled, in this order.
    private var defaultServerSliders: [(type: Int, order: Int, enabled: Bool)] {
        (1...12).map { (type: $0, order: $0 - 1, enabled: true) }
    }

    @Test @MainActor func theServerDefaultsBecomeTheEightRowsLagoonCanDraw() throws {
        let rows = SeerrDiscoverLayout.rows(for: try sliders(defaultServerSliders))
        #expect(rows == [
            .media(.watchlist),
            .media(.trending),
            .media(.popular(.movie)),
            .genres(.movie),
            .media(.upcoming(.movie)),
            .media(.popular(.tv)),
            .genres(.tv),
            .media(.upcoming(.tv)),
        ])
    }

    /// Recently Added and Recent Requests duplicate Home and the Requests
    /// chip; Studios and Networks are curated brand-logo shelves in the web
    /// client rather than anything the API serves.
    @Test @MainActor func theFourSkippedTypesProduceNoRow() throws {
        let rows = SeerrDiscoverLayout.rows(for: try sliders([
            (type: 1, order: 0, enabled: true),   // recently added
            (type: 2, order: 1, enabled: true),   // recent requests
            (type: 8, order: 2, enabled: true),   // studios
            (type: 12, order: 3, enabled: true),  // networks
            (type: 4, order: 4, enabled: true),   // trending
        ]))
        #expect(rows == [.media(.trending)])
    }

    /// Re-ordering sliders in Jellyseerr has to re-order Discover, which is
    /// the whole reason for reading the endpoint rather than hardcoding.
    @Test @MainActor func rowsFollowTheServersOrderNotTheResponseOrder() throws {
        let rows = SeerrDiscoverLayout.rows(for: try sliders([
            (type: 4, order: 9, enabled: true),   // trending, last
            (type: 9, order: 1, enabled: true),   // popular tv
            (type: 5, order: 0, enabled: true),   // popular movies, first
        ]))
        #expect(rows == [.media(.popular(.movie)), .media(.popular(.tv)), .media(.trending)])
    }

    @Test @MainActor func aDisabledSliderIsLeftOut() throws {
        let rows = SeerrDiscoverLayout.rows(for: try sliders([
            (type: 4, order: 0, enabled: false),
            (type: 5, order: 1, enabled: true),
        ]))
        #expect(rows == [.media(.popular(.movie))])
    }

    /// A newer Jellyseerr can add slider types. One this build has never
    /// heard of must drop out quietly rather than fail decoding and take the
    /// whole layout with it.
    @Test @MainActor func anUnknownSliderTypeIsSkippedWithoutLosingTheRest() throws {
        let rows = SeerrDiscoverLayout.rows(for: try sliders([
            (type: 4, order: 0, enabled: true),
            (type: 987, order: 1, enabled: true),
            (type: 5, order: 2, enabled: true),
        ]))
        #expect(rows == [.media(.trending), .media(.popular(.movie))])
    }

    /// An older server without the endpoint, or one whose sliders are all
    /// types Lagoon skips, must still produce a Discover page.
    @Test @MainActor func nothingRenderableFallsBackToTheDefaultArrangement() throws {
        #expect(SeerrDiscoverLayout.rows(for: []) == SeerrDiscoverLayout.fallback)
        let unrenderable = try sliders([(type: 8, order: 0, enabled: true)])
        #expect(SeerrDiscoverLayout.rows(for: unrenderable) == SeerrDiscoverLayout.fallback)
    }

    /// The fallback is Jellyseerr's own default order with the skipped types
    /// removed, so a server that will not answer looks like one that does.
    @Test @MainActor func theFallbackMatchesWhatTheServerDefaultsWouldProduce() throws {
        #expect(SeerrDiscoverLayout.rows(for: try sliders(defaultServerSliders)) == SeerrDiscoverLayout.fallback)
    }

    /// Rail identity keys a `ForEach` and an accessibility identifier, so two
    /// rows must never collide — genres and popular of the same media type
    /// are the near miss.
    @Test @MainActor func everyRowInTheDefaultLayoutHasADistinctIdentity() {
        let ids = SeerrDiscoverLayout.fallback.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test @MainActor func aGenreSourceCarriesItsNameAsTheCatalogueTitle() {
        let source = SeerrCatalogSource.genre(.movie, id: 28, name: "Action")
        #expect(source.title == "Action")
        #expect(source.id == "genre.movie.28")
    }

    /// `discover/genreslider/*` sends backdrops; a detail page's genres do
    /// not send the key at all and must decode to an empty list rather than
    /// throwing.
    @Test @MainActor func aGenreWithoutBackdropsStillDecodes() throws {
        let genre = try JSONDecoder().decode(
            SeerrGenre.self,
            from: Data(#"{"id":28,"name":"Action"}"#.utf8)
        )
        #expect(genre.backdrops.isEmpty)
        #expect(genre.name == "Action")
    }
}

@Suite("Seerr image sizes")
struct SeerrImageURLTests {
    /// TMDB answers 400 for a width it does not have a rendition for, so an
    /// arbitrary layout width has to be snapped to a real one. Verified
    /// against image.tmdb.org: w300/w780/w1280 return 200, w720 returns 400.
    @Test @MainActor func anUnsupportedWidthSnapsUpToOneTMDBActuallyServes() {
        let url = SeerrClient.imageURL(path: "/abc.jpg", width: 720)
        #expect(url?.absoluteString == "https://image.tmdb.org/t/p/w780/abc.jpg")
    }

    @Test @MainActor func asupportedWidthIsUsedUnchanged() {
        #expect(
            SeerrClient.imageURL(path: "/abc.jpg", width: 500)?.absoluteString
                == "https://image.tmdb.org/t/p/w500/abc.jpg"
        )
    }

    /// Anything past the largest rendition asks for the original rather than
    /// inventing a width.
    @Test @MainActor func anOversizeRequestFallsBackToTheOriginal() {
        #expect(
            SeerrClient.imageURL(path: "/abc.jpg", width: 4000)?.absoluteString
                == "https://image.tmdb.org/t/p/original/abc.jpg"
        )
    }

    @Test @MainActor func aPathWithoutALeadingSlashStillBuilds() {
        #expect(
            SeerrClient.imageURL(path: "abc.jpg", width: 92)?.absoluteString
                == "https://image.tmdb.org/t/p/w92/abc.jpg"
        )
    }

    @Test @MainActor func noPathIsNoURL() {
        #expect(SeerrClient.imageURL(path: nil, width: 500) == nil)
        #expect(SeerrClient.imageURL(path: "", width: 500) == nil)
    }
}
