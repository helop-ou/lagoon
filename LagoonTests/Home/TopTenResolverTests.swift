import Foundation
import Testing
@testable import Lagoon

@Suite("Top 10 resolver")
struct TopTenResolverTests {
    @Test func matchesExactProvidersInDiscoveryOrderAndDeduplicatesEditions() throws {
        let library = try items(#"""
        [
            {"id":"movie-a","type":"Movie","providerIds":{"Tmdb":"10"}},
            {"id":"movie-a-4k","type":"Movie","providerIds":{"Tmdb":"10"}},
            {"id":"movie-b","type":"Movie","providerIds":{"tmdb":"20"}},
            {"id":"movie-c","type":"Movie","providerIds":{"TMDB":"30"}},
            {"id":"movie-d","type":"Movie","providerIds":{"Tmdb":"40"}},
            {"id":"show-20","type":"Series","providerIds":{"Tmdb":"20"}},
            {"id":"title-match","type":"Movie","name":"Missing"}
        ]
        """#)
        let ranked = try discoveries(#"""
        [
            {"id":999,"title":"Missing"}, {"id":20,"title":"B"},
            {"id":10,"title":"A"}, {"id":20,"title":"Duplicate"},
            {"id":40,"title":"D"}, {"id":30,"title":"C"}
        ]
        """#)

        let resolved = TopTenResolver.resolve(discoveries: ranked, library: library, type: .movie)
        #expect(resolved.map(\.id) == ["movie-b", "movie-a", "movie-d", "movie-c"])
        #expect(resolved == [library[2], library[0], library[4], library[3]])
    }

    @Test func movieAndShowCataloguesCannotBorrowEachOthersRank() throws {
        let library = try items((1...4).map {
            #"{"id":"show\#($0)","type":"Series","providerIds":{"Tmdb":"\#($0)"}}"#
        })
        let ranked = try discoveries(#"""
        [
            {"id":4,"mediaType":"movie"}, {"id":3,"mediaType":"person"},
            {"id":1,"mediaType":"tv"}, {"id":2,"mediaType":"tv"},
            {"id":3,"mediaType":"tv"}, {"id":4,"mediaType":"tv"}
        ]
        """#)
        #expect(TopTenResolver.resolve(discoveries: ranked, library: library, type: .series).map(\.id)
            == ["show1", "show2", "show3", "show4"])
        #expect(TopTenResolver.resolve(discoveries: ranked, library: library, type: .movie).isEmpty)
    }

    @Test func onlyFirstTenMatchingTitlesSurvive() throws {
        let library = try items((1...12).map {
            #"{"id":"m\#($0)","type":"Movie","providerIds":{"Tmdb":"\#($0)"}}"#
        })
        let ranked = try discoveries("[" + (1...12).reversed().map {
            #"{"id":\#($0)}"#
        }.joined(separator: ",") + "]")
        #expect(TopTenResolver.resolve(discoveries: ranked, library: library, type: .movie).map(\.id)
            == (3...12).reversed().map { "m\($0)" })
    }

    @Test func fewerThanFourUniqueExactMatchesOmitsTheRow() throws {
        let library = try items(#"""
        [
            {"id":"a","type":"Movie","providerIds":{"Tmdb":"1"}},
            {"id":"b","type":"Movie","providerIds":{"Tmdb":"2"}},
            {"id":"c","type":"Movie","providerIds":{"Tmdb":"3"}},
            {"id":"leading-zero","type":"Movie","providerIds":{"Tmdb":"04"}},
            {"id":"other-provider","type":"Movie","providerIds":{"Imdb":"5"}},
            {"id":"blank","type":"Movie","providerIds":{"Tmdb":""}}
        ]
        """#)
        let ranked = try discoveries(#"[{"id":1},{"id":2},{"id":3},{"id":1},{"id":4},{"id":5}]"#)
        #expect(TopTenResolver.resolve(discoveries: ranked, library: library, type: .movie).isEmpty)
    }

    private func items(_ json: String) throws -> [MediaItem] {
        try JSONDecoder().decode([MediaItem].self, from: Data(json.utf8))
    }

    private func items(_ records: [String]) throws -> [MediaItem] {
        try items("[" + records.joined(separator: ",") + "]")
    }

    private func discoveries(_ json: String) throws -> [SeerrDiscoverResult] {
        try JSONDecoder().decode([SeerrDiscoverResult].self, from: Data(json.utf8))
    }
}
