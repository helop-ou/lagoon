import Foundation
import Testing
@testable import Lagoon

/// What Home calls a collection, and what it draws it with. A real library
/// measured 173 collections: 35 non-empty, 18 with more than one title, and
/// 11 of those 18 with no landscape artwork.
@Suite("Collection shelf")
struct CollectionShelfTests {
    private func collection(
        id: String = "c1",
        name: String,
        childCount: Int?,
        thumb: Bool = false,
        backdrop: Bool = false,
        genres: [String]? = nil
    ) throws -> MediaItem {
        var fields: [String] = [
            #""Id":"\#(id)""#,
            #""Type":"BoxSet""#,
            #""Name":"\#(name)""#,
        ]
        if let childCount { fields.append(#""ChildCount":\#(childCount)"#) }
        if thumb { fields.append(#""ImageTags":{"Thumb":"t"}"#) }
        if backdrop { fields.append(#""BackdropImageTags":["b"]"#) }
        if let genres {
            let list = genres.map { "\"\($0)\"" }.joined(separator: ",")
            fields.append(#""Genres":[\#(list)]"#)
        }
        return try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    private func movie(
        id: String = "m1",
        name: String = "Film",
        year: Int? = nil,
        thumb: Bool = false,
        backdrop: Bool = false,
        genres: [String] = []
    ) throws -> MediaItem {
        var fields: [String] = [#""Id":"\#(id)""#, #""Type":"Movie""#, #""Name":"\#(name)""#]
        if let year { fields.append(#""ProductionYear":\#(year)"#) }
        if thumb { fields.append(#""ImageTags":{"Thumb":"t"}"#) }
        if backdrop { fields.append(#""BackdropImageTags":["b"]"#) }
        if !genres.isEmpty {
            let list = genres.map { "\"\($0)\"" }.joined(separator: ",")
            fields.append(#""Genres":[\#(list)]"#)
        }
        return try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    // MARK: - Which collections earn a card

    @Test func theFranchiseStubsAServerInventsAreNotCollections() throws {
        // A scrape creates a collection off one owned film; most hold nothing.
        let all = try [
            collection(id: "empty", name: "The Dark Knight Collection", childCount: 0),
            collection(id: "unknown", name: "Alien Collection", childCount: nil),
            collection(id: "single", name: "Avatar Collection", childCount: 1),
            collection(id: "real", name: "AVP Collection", childCount: 2),
        ]

        #expect(CollectionShelf.ranked(all).map(\.id) == ["real"])
    }

    @Test func theBiggestFranchisesComeFirst() throws {
        let all = try [
            collection(id: "avp", name: "AVP Collection", childCount: 2),
            collection(id: "after", name: "After Collection", childCount: 5),
            collection(id: "apes", name: "Planet of the Apes Collection", childCount: 4),
        ]

        #expect(CollectionShelf.ranked(all).map(\.id) == ["after", "apes", "avp"])
    }

    @Test func equalSizedCollectionsHoldStillBetweenLoads() throws {
        // Without the name tiebreak the row reshuffles on every load.
        let all = try [
            collection(id: "zombieland", name: "Zombieland Collection", childCount: 2),
            collection(id: "avp", name: "AVP Collection", childCount: 2),
            collection(id: "saw", name: "Saw Collection", childCount: 2),
        ]

        #expect(CollectionShelf.ranked(all).map(\.id) == ["avp", "saw", "zombieland"])
    }

    @Test func theRowStopsBeforeItStopsBeingBrowsable() throws {
        let all = try (1...30).map {
            try collection(id: "c\($0)", name: "Collection \($0)", childCount: 2)
        }

        #expect(CollectionShelf.ranked(all).count == CollectionShelf.maximumVisible)
    }

    @Test func aLibraryWithNoRealCollectionsGetsNoRow() throws {
        let all = try (1...50).map {
            try collection(id: "c\($0)", name: "Collection \($0)", childCount: 0)
        }

        #expect(CollectionShelf.ranked(all).isEmpty)
    }

    // MARK: - What the card is painted with

    @Test func aCollectionWithItsOwnArtworkBorrowsNothing() throws {
        let illustrated = try collection(name: "Greenland Collection", childCount: 2, thumb: true)
        let borrowed = try movie(id: "borrowed", thumb: true)

        let shelf = CollectionShelf.shelf([illustrated], borrowedArtwork: ["c1": borrowed])

        #expect(shelf.first?.artwork?.id == illustrated.id)
    }

    @Test func aBackdropCountsAsArtworkAndAPosterDoesNot() throws {
        // Home's rows are 16:9; a collection's Primary is a poster and would
        // crop to a strip.
        let poster = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"p","Type":"BoxSet","ImageTags":{"Primary":"x"}}"#.utf8)
        )

        #expect(!CollectionShelf.hasLandscapeArtwork(poster))
        #expect(try CollectionShelf.hasLandscapeArtwork(collection(name: "b", childCount: 2, backdrop: true)))
    }

    @Test func anUnillustratedCollectionWearsItsFirstFilm() throws {
        let bare = try collection(id: "apes", name: "Planet of the Apes Collection", childCount: 4)
        let contents = try [
            movie(id: "rise", name: "Rise", year: 2011, thumb: true),
            movie(id: "dawn", name: "Dawn", year: 2014, thumb: true),
        ]

        let source = CollectionShelf.artworkSource(from: contents)
        let shelf = CollectionShelf.shelf([bare], borrowedArtwork: ["apes": source].compactMapValues { $0 })

        #expect(source?.id == "rise")
        #expect(shelf.first?.artwork?.id == "rise")
    }

    @Test func itSkipsPastContentsThatCannotFillACardEither() throws {
        let contents = try [
            movie(id: "undecorated", name: "First"),
            movie(id: "decorated", name: "Second", backdrop: true),
        ]

        #expect(CollectionShelf.artworkSource(from: contents)?.id == "decorated")
    }

    @Test func aCollectionNothingCanIllustrateStillGetsACard() throws {
        // No artwork falls back to a gradient, not a missing card.
        let bare = try collection(id: "bare", name: "Despicable Me Collection", childCount: 2)

        let shelf = CollectionShelf.shelf([bare])

        #expect(shelf.count == 1)
        #expect(shelf.first?.artwork == nil)
        #expect(shelf.first?.titleCount == 2)
    }

    // MARK: - What the card and the page say

    @Test func theCountReadsAsProseAndNeverPromisesFilms() throws {
        // "Title", not "film": a collection can hold series.
        #expect(CollectionShelf.countLabel(1) == "1 title")
        #expect(CollectionShelf.countLabel(5) == "5 titles")
    }

    @Test func theYearRangeSpansTheFranchise() throws {
        let contents = try [
            movie(id: "a", year: 2014),
            movie(id: "b", year: 2011),
            movie(id: "c", year: 2024),
        ]

        #expect(CollectionShelf.yearsLabel(contents) == "2011 – 2024")
    }

    @Test func aFranchiseFromOneYearIsNotARange() throws {
        let contents = try [movie(id: "a", year: 2019), movie(id: "b", year: 2019)]

        #expect(CollectionShelf.yearsLabel(contents) == "2019")
    }

    @Test func anUndatedFranchiseSaysNothingAboutYears() throws {
        #expect(CollectionShelf.yearsLabel(try [movie(id: "a"), movie(id: "b")]) == nil)
        #expect(CollectionShelf.yearsLabel([]) == nil)
    }

    @Test func aCollectionWithoutGenresBorrowsThemFromWhatIsInside() throws {
        // 7 of the reference library's 18 real collections carry no genres.
        let bare = try collection(name: "AVP Collection", childCount: 2)
        let contents = try [
            movie(id: "a", genres: ["Horror", "Action"]),
            movie(id: "b", genres: ["Horror", "Science Fiction"]),
        ]

        #expect(CollectionShelf.genres(of: bare, contents: contents) == ["Horror", "Action", "Science Fiction"])
    }

    @Test func aCollectionWithItsOwnGenresKeepsThem() throws {
        let described = try collection(
            name: "After Collection",
            childCount: 5,
            genres: ["Drama", "Romance"]
        )
        let contents = try [movie(id: "a", genres: ["Horror"])]

        #expect(CollectionShelf.genres(of: described, contents: contents) == ["Drama", "Romance"])
    }

    // MARK: - Search

    @Test func searchingAFranchiseNameDoesNotSurfaceItsStub() throws {
        // "Alien" matches the films and the empty Alien Collection stub.
        let results = try [
            movie(id: "film", name: "Alien"),
            collection(id: "stub", name: "Alien Collection", childCount: 0),
            collection(id: "real", name: "AVP Collection", childCount: 2),
        ]

        #expect(SearchViewModel.presentable(results).map(\.id) == ["film", "real"])
    }
}
