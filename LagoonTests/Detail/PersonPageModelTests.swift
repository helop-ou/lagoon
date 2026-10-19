import Foundation
import Testing
@testable import Lagoon

/// The person page with Seerr: which TMDB credits reach the rail, and how a
/// library person and a TMDB person find each other. Serialized: the
/// fixture's routes are shared state.
@Suite("Person page with Seerr", .serialized)
@MainActor
struct PersonPageModelTests {
    private func decodeCredits(_ json: String) throws -> SeerrPersonCredits {
        try JSONDecoder().decode(SeerrPersonCredits.self, from: Data(json.utf8))
    }

    // MARK: Filmography

    @Test func theRailKeepsWorkAndDropsSelfAppearancesTheLibraryAndRepeats() throws {
        let credits = try decodeCredits(#"""
        {
          "id": 31,
          "cast": [
            { "id": 13, "mediaType": "movie", "title": "Forrest Gump", "posterPath": "/fg.jpg", "voteCount": 30000, "character": "Forrest Gump" },
            { "id": 2, "mediaType": "movie", "title": "Big", "posterPath": "/big.jpg", "voteCount": 4000, "character": "Josh" },
            { "id": 3, "mediaType": "movie", "title": "Toy Story", "posterPath": "/ts.jpg", "voteCount": 20000, "character": "Woody (voice)",
              "mediaInfo": { "tmdbId": 3, "status": 5 } },
            { "id": 4, "mediaType": "tv", "name": "Band of Brothers", "posterPath": "/bob.jpg", "voteCount": 9000, "character": "",
              "mediaInfo": { "tmdbId": 4, "status": 4 } },
            { "id": 5, "mediaType": "tv", "name": "The Tonight Show", "posterPath": "/ts.jpg", "voteCount": 500, "genreIds": [10767, 35] },
            { "id": 6, "mediaType": "movie", "title": "Making Of", "posterPath": "/mo.jpg", "voteCount": 50, "character": "Self (archive footage)" },
            { "id": 7, "mediaType": "tv", "name": "The Oscars", "posterPath": "/o.jpg", "voteCount": 300, "character": "Himself - Host", "genreIds": [] },
            { "id": 8, "mediaType": "movie", "title": "Lost Reel", "voteCount": 9, "character": "Hank" },
            { "id": 9, "mediaType": "movie", "title": "Selfridge Story", "posterPath": "/s.jpg", "voteCount": 10, "character": "Selfridge" },
            { "id": 10, "mediaType": "movie", "title": "In The Library", "posterPath": "/l.jpg", "voteCount": 8000, "character": "Hero" },
            { "id": 11, "mediaType": "movie", "title": "Requested", "posterPath": "/r.jpg", "voteCount": 100, "character": "Lead",
              "mediaInfo": { "tmdbId": 11, "status": 2 } },
            { "mediaType": "movie", "title": "No Id", "posterPath": "/x.jpg" }
          ],
          "crew": [
            { "id": 13, "mediaType": "movie", "title": "Forrest Gump", "posterPath": "/fg.jpg", "voteCount": 30000, "job": "Producer" },
            { "id": 2, "mediaType": "tv", "name": "Big (series)", "posterPath": "/bigtv.jpg", "voteCount": 30, "job": "Director" }
          ]
        }
        """#)

        let rail = credits.filmography(excluding: ["movie:10"])

        // Most voted first. One card per title, with the movie and the show
        // of the same TMDB id kept apart. A pending request stays requestable.
        #expect(rail.map { SeerrPersonCredits.key($0) } == ["movie:13", "movie:2", "movie:11", "tv:2", "movie:9"])
    }

    @Test func aBrokenCreditCostsOnlyItself() throws {
        let credits = try decodeCredits(#"""
        { "cast": [ { "title": "No Id" }, { "id": 1, "mediaType": "movie", "posterPath": "/a.jpg" } ], "crew": "nope" }
        """#)
        #expect(credits.cast.map(\.media.id) == [1])
        #expect(credits.crew.isEmpty)
    }

    @Test func aLibraryTitleKeysByItsTMDBIdAndKind() throws {
        let movie = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"""
        { "Id": "m", "Type": "Movie", "ProviderIds": { "Tmdb": "13" } }
        """#.utf8))
        let series = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"""
        { "Id": "s", "Type": "Series", "ProviderIds": { "tmdb": "4" } }
        """#.utf8))
        let untagged = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"""
        { "Id": "u", "Type": "Movie" }
        """#.utf8))
        #expect(SeerrPersonCredits.key(movie) == "movie:13")
        #expect(SeerrPersonCredits.key(series) == "tv:4")
        #expect(SeerrPersonCredits.key(untagged) == nil)
    }

    // MARK: Seerr people

    @Test func aPersonSearchResultOpensTheirPage() throws {
        let page = try JSONDecoder().decode(SeerrDiscoverPage.self, from: Data(#"""
        { "page": 1, "totalPages": 1, "results": [
          { "id": 31, "mediaType": "person", "name": "Tom Hanks", "profilePath": "/th.jpg" },
          { "id": 13, "mediaType": "movie", "title": "Forrest Gump" }
        ] }
        """#.utf8))
        #expect(page.results.compactMap(\.person) == [SeerrPerson(id: 31, name: "Tom Hanks", profilePath: "/th.jpg")])
    }

    @Test func aSeerrCreditWithoutAPersonIdOpensNothing() {
        #expect(SeerrMediaDetailView.person(id: 0, name: "Someone", profilePath: nil) == nil)
        #expect(SeerrMediaDetailView.person(id: 31, name: nil, profilePath: nil) == nil)
        #expect(SeerrMediaDetailView.person(id: 31, name: "Tom Hanks", profilePath: nil)?.id == 31)
    }

    @Test func aTMDBBiographyReadsLikeALibraryOne() throws {
        let details = try JSONDecoder().decode(SeerrPersonDetails.self, from: Data(#"""
        { "id": 31, "name": "Tom Hanks", "birthday": "1956-07-09", "deathday": null,
          "placeOfBirth": "Concord, California, USA", "biography": "An actor." }
        """#.utf8))
        #expect(PersonDetails.lifeFacts(
            born: details.birthday, place: details.placeOfBirth, died: details.deathday,
            locale: Locale(identifier: "en_US")
        ) == ["Born July 9, 1956 in Concord, California, USA"])
    }

    // MARK: Loading

    @Test func aLibraryPersonGainsTheirTMDBTitlesWithoutRepeatingTheLibrary() async throws {
        let clients = makeClients()
        let model = PersonPageModel(subject: .library(try libraryPerson()))

        await model.load(jellyfin: clients.jellyfin, seerr: clients.seerr)

        #expect(model.titles?.map(\.id) == ["gump"])
        #expect(model.tmdbTitles?.map(\.id) == [2])
        #expect(PersonPageFixture.paths.contains("/api/v1/person/31/combined_credits"))
    }

    @Test func withoutSeerrALibraryPersonPageIsUnchanged() async throws {
        let clients = makeClients()
        let model = PersonPageModel(subject: .library(try libraryPerson()))

        await model.load(jellyfin: clients.jellyfin, seerr: nil)

        #expect(model.titles?.map(\.id) == ["gump"])
        #expect(model.tmdbTitles == nil)
        #expect(!model.tmdbTitlesFailed)
        #expect(!PersonPageFixture.paths.contains { $0.hasPrefix("/api/v1") })
    }

    @Test func aLibraryPersonWithoutATMDBIdNeverAsksSeerr() async throws {
        let clients = makeClients()
        PersonPageFixture.set(path: "/Users/user/Items/hanks", body: #"{"Id":"hanks","Name":"Tom Hanks"}"#)
        let model = PersonPageModel(subject: .library(try libraryPerson()))

        await model.load(jellyfin: clients.jellyfin, seerr: clients.seerr)

        #expect(model.tmdbTitles == nil)
        #expect(!PersonPageFixture.paths.contains { $0.hasPrefix("/api/v1") })
    }

    @Test func aTMDBPersonFindsTheirLibraryPersonOnlyByTMDBId() async throws {
        let clients = makeClients()
        let model = PersonPageModel(subject: .tmdb(SeerrPerson(id: 31, name: "Tom Hanks", profilePath: nil)))

        await model.load(jellyfin: clients.jellyfin, seerr: clients.seerr)

        // The namesake listed first has another TMDB id.
        #expect(model.libraryDetails?.id == "hanks")
        #expect(!model.isOutsideLibrary)
        #expect(model.titles?.map(\.id) == ["gump"])
        #expect(model.tmdbTitles?.map(\.id) == [2])
        #expect(model.tmdbDetails?.biography == "An actor.")
        #expect(model.biography == "An actor.")
    }

    @Test func aTMDBPersonTheLibraryDoesNotKnowHasNoLibraryRail() async throws {
        let clients = makeClients()
        PersonPageFixture.set(path: "/Persons", body: #"{"Items":[{"Id":"other","Name":"Tom Hanks","ProviderIds":{"Tmdb":"999"}}]}"#)
        let model = PersonPageModel(subject: .tmdb(SeerrPerson(id: 31, name: "Tom Hanks", profilePath: nil)))

        await model.load(jellyfin: clients.jellyfin, seerr: clients.seerr)

        #expect(model.isOutsideLibrary)
        #expect(model.titles?.isEmpty == true)
        // Nothing to exclude, so the library title shows on the TMDB rail.
        #expect(model.tmdbTitles?.map(\.id) == [13, 2])
        #expect(!PersonPageFixture.paths.contains("/Users/user/Items"))
    }

    @Test func aFailedRefreshKeepsTheTMDBTitles() async throws {
        let clients = makeClients()
        let model = PersonPageModel(subject: .tmdb(SeerrPerson(id: 31, name: "Tom Hanks", profilePath: nil)))
        await model.load(jellyfin: clients.jellyfin, seerr: clients.seerr)

        PersonPageFixture.set(path: "/api/v1/person/31/combined_credits", body: nil)
        await model.load(jellyfin: clients.jellyfin, seerr: clients.seerr)

        #expect(model.tmdbTitles?.map(\.id) == [2])
        #expect(!model.tmdbTitlesFailed)
    }

    // MARK: Fixture

    private func libraryPerson() throws -> Person {
        try JellyfinClient.decoder.decode(Person.self, from: Data(#"{"Id":"hanks","Name":"Tom Hanks"}"#.utf8))
    }

    private func makeClients() -> (seerr: SeerrClient, jellyfin: JellyfinClient) {
        PersonPageFixture.reset()
        StubURLProtocol.register(host: "seerr.person.test", handler: PersonPageFixture.respond)
        StubURLProtocol.register(host: "jellyfin.person.test", handler: PersonPageFixture.respond)
        let seerr = SeerrClient(session: URLSession(configuration: StubURLProtocol.configuration()), requestTimeout: 5)
        seerr.configure(serverURL: URL(string: "https://seerr.person.test")!)
        seerr.setSessionCookie("session")
        let jellyfin = StubURLProtocol.makeJellyfinClient(host: "jellyfin.person.test", deviceId: "person-page-tests")
        return (seerr, jellyfin)
    }
}

/// Tom Hanks on both servers: the library holds Forrest Gump, TMDB adds Big.
/// Paths answer from a table that tests can edit. A nil body fails the call.
private enum PersonPageFixture {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var bodies: [String: String] = [:]
    private nonisolated(unsafe) static var recorded: [String] = []

    static var paths: [String] { lock.withLock { recorded } }

    static func reset() {
        lock.withLock {
            recorded = []
            bodies = [
                "/Users/user/Items/hanks":
                    #"{"Id":"hanks","Name":"Tom Hanks","ProviderIds":{"Tmdb":"31"}}"#,
                "/Users/user/Items":
                    #"{"Items":[{"Id":"gump","Name":"Forrest Gump","Type":"Movie","ProviderIds":{"Tmdb":"13"}}],"TotalRecordCount":1}"#,
                "/Persons":
                    #"{"Items":[{"Id":"namesake","Name":"Tom Hanks","ProviderIds":{"Tmdb":"7"}},{"Id":"hanks","Name":"Tom Hanks","ProviderIds":{"Tmdb":"31"}}]}"#,
                "/api/v1/person/31":
                    #"{"id":31,"name":"Tom Hanks","biography":"An actor."}"#,
                "/api/v1/person/31/combined_credits":
                    #"{"id":31,"cast":[{"id":13,"mediaType":"movie","title":"Forrest Gump","posterPath":"/fg.jpg","voteCount":30000},{"id":2,"mediaType":"movie","title":"Big","posterPath":"/big.jpg","voteCount":4000}],"crew":[]}"#,
            ]
        }
    }

    static func set(path: String, body: String?) {
        lock.withLock { bodies[path] = body }
    }

    static func respond(to request: URLRequest) throws -> (Int, [String: String], Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let body = lock.withLock { () -> String? in
            recorded.append(url.path)
            return bodies[url.path]
        }
        guard let body else { throw URLError(.notConnectedToInternet) }
        return (200, ["Content-Type": "application/json"], Data(body.utf8))
    }
}
