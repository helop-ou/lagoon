import Foundation
import Testing
@testable import Lagoon

@Suite("Home genre discovery")
struct HomeGenreDiscoveryTests {
    @Test func navigationRoutesKeepMovieAndShowGenresDistinct() {
        let movies = ContentNavigationRoute.genre(name: "Action", includeTypes: [.movie])
        let shows = ContentNavigationRoute.genre(name: "Action", includeTypes: [.series])

        #expect(movies != shows)
        #expect(Set([movies, shows]).count == 2)
    }

    /// A refreshed copy of an item on the stack must still be the same route,
    /// or the path reorders; a different item must never be.
    @Test func anItemRouteIsItsItemIDHoweverStaleTheCopy() throws {
        let items = try candidates()
        let stale = items[0]
        let refreshed = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"\#(stale.id)","Name":"Renamed","Type":"Movie","CommunityRating":1.0}"#.utf8)
        )
        #expect(stale != refreshed)

        #expect(ContentNavigationRoute.item(stale) == .item(refreshed))
        #expect(Set([ContentNavigationRoute.item(stale), .item(refreshed)]).count == 1)
        #expect(ContentNavigationRoute.item(items[0]) != .item(items[1]))
        #expect(Set([ContentNavigationRoute.item(items[0]), .item(items[1])]).count == 2)
    }

    private func candidates() throws -> [MediaItem] {
        let data = Data(#"""
        {"Items":[
            {"Id":"action-low","Name":"Action Low","Type":"Movie","CommunityRating":6.0,"Genres":["Action"],"BackdropImageTags":["low"]},
            {"Id":"drama-best-no-art","Name":"Drama Best","Type":"Series","CommunityRating":9.8,"Genres":["Drama"]},
            {"Id":"action-best","Name":"Action Best","Type":"Movie","CommunityRating":9.4,"Genres":["Action"],"BackdropImageTags":["best"]},
            {"Id":"drama-art","Name":"Drama Art","Type":"Series","CommunityRating":8.5,"Genres":["Drama"],"ImageTags":{"Thumb":"thumb"}},
            {"Id":"comedy","Name":"Comedy","Type":"Movie","CommunityRating":7.5,"Genres":["Comedy"],"BackdropImageTags":["comedy"]}
        ]}
        """#.utf8)
        return try JellyfinClient.decoder.decode(ItemsPage.self, from: data).items
    }

    @Test func highestRatedLandscapeTitleBecomesEachGenreBackground() throws {
        let genres = [
            MediaGenre(id: "action", name: "Action"),
            MediaGenre(id: "drama", name: "Drama"),
            MediaGenre(id: "comedy", name: "Comedy"),
            MediaGenre(id: "stale", name: "Stale Genre"),
        ]

        let shelf = GenreShelfResolver.resolve(catalog: genres, candidates: try candidates())

        #expect(shelf.map(\.name) == ["Action", "Drama", "Comedy"])
        #expect(shelf.first(where: { $0.name == "Action" })?.artwork?.id == "action-best")
        // The top Drama item has no landscape art, so the next one supplies it.
        #expect(shelf.first(where: { $0.name == "Drama" })?.artwork?.id == "drama-art")
    }

    @Test func candidatesProvideAUsefulFallbackWhenTheGenreEndpointIsUnavailable() throws {
        let shelf = GenreShelfResolver.resolve(
            catalog: [],
            candidates: try candidates(),
            limit: 2
        )

        #expect(shelf.map(\.name) == ["Action", "Drama"])
        #expect(shelf.allSatisfy { $0.id.hasPrefix("derived-") })
    }

    @Test func movieAndShowGenreShelvesDoNotMixMediaTypes() throws {
        let genres = [
            MediaGenre(id: "action", name: "Action"),
            MediaGenre(id: "drama", name: "Drama"),
            MediaGenre(id: "comedy", name: "Comedy"),
        ]

        let movies = GenreShelfResolver.resolve(
            catalog: genres,
            candidates: try candidates(),
            includeTypes: [.movie]
        )
        let shows = GenreShelfResolver.resolve(
            catalog: genres,
            candidates: try candidates(),
            includeTypes: [.series]
        )

        #expect(movies.map(\.name) == ["Action", "Comedy"])
        #expect(shows.map(\.name) == ["Drama"])
    }
}
