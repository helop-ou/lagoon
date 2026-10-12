import Foundation
import Testing
@testable import Lagoon

/// The person page: what a person's item decodes to, how their dates and
/// birthplace read, and the query for what the library credits them in.
@Suite("Person details", .serialized)
struct PersonDetailsTests {
    private let english = Locale(identifier: "en_US")

    private func decode(_ json: String) throws -> PersonDetails {
        try JellyfinClient.decoder.decode(PersonDetails.self, from: Data(json.utf8))
    }

    @Test func aFullPersonItemDecodes() throws {
        let person = try decode(#"""
        {
          "Id": "person-1",
          "Name": "Judith O'Dea",
          "Type": "Person",
          "Overview": "An American actress.",
          "PremiereDate": "1945-04-20T00:00:00.0000000Z",
          "ProductionLocations": ["Pittsburgh, Pennsylvania, USA"],
          "ProviderIds": { "Tmdb": "97913" },
          "ImageTags": { "Primary": "tag-1" }
        }
        """#)
        #expect(person.name == "Judith O'Dea")
        #expect(person.premiereDate == "1945-04-20T00:00:00.0000000Z")
        #expect(person.providerIds?["Tmdb"] == "97913")
        #expect(person.imageTags?["Primary"] == "tag-1")
        #expect(person.lifeFacts(locale: english) == ["Born April 20, 1945 in Pittsburgh, Pennsylvania, USA"])
    }

    @Test func missingOrMalformedFieldsLeaveAUsablePerson() throws {
        let person = try decode(#"""
        { "Id": "person-1", "Name": 7, "PremiereDate": 1945, "ProductionLocations": "Pittsburgh", "ImageTags": [] }
        """#)
        #expect(person.id == "person-1")
        #expect(person.name == nil)
        #expect(person.overview == nil)
        #expect(person.premiereDate == nil)
        #expect(person.productionLocations == nil)
        #expect(person.imageTags == nil)
        #expect(person.lifeFacts(locale: english).isEmpty)
    }

    @Test func aPersonWithoutAnIdIsRejected() {
        #expect(throws: DecodingError.self) {
            try decode(#"{ "Name": "Nobody" }"#)
        }
    }

    @Test func theBirthdayIsReadFromTheDigitsNotShiftedByATimeZone() {
        // Late in the day UTC is already the next day east of Greenwich.
        #expect(PersonDetails.displayDate("1945-04-20T23:30:00.0000000Z", locale: english) == "April 20, 1945")
        #expect(PersonDetails.displayDate("1945-04-20", locale: english) == "April 20, 1945")
    }

    @Test func anUnreadableDateIsLeftOut() {
        #expect(PersonDetails.displayDate(nil, locale: english) == nil)
        #expect(PersonDetails.displayDate("", locale: english) == nil)
        #expect(PersonDetails.displayDate("sometime in 1945", locale: english) == nil)
        #expect(PersonDetails.displayDate("1945-13-01T00:00:00Z", locale: english) == nil)
        #expect(PersonDetails.displayDate("0001-01-01T00:00:00.0000000Z", locale: english) == nil)
    }

    @Test func lifeFactsSayOnlyWhatIsKnown() throws {
        let placeOnly = try decode(#"{ "Id": "p", "ProductionLocations": ["", "Lyon, France"] }"#)
        #expect(placeOnly.lifeFacts(locale: english) == ["Born in Lyon, France"])

        let both = try decode(#"""
        { "Id": "p", "PremiereDate": "1902-12-08T00:00:00.0000000Z", "EndDate": "1984-01-30T00:00:00.0000000Z" }
        """#)
        #expect(both.lifeFacts(locale: english) == ["Born December 8, 1902", "Died January 30, 1984"])
    }

    @Test func theBiographySplitsIntoParagraphsAtLineBreaks() {
        #expect(PersonDetails.paragraphs(of: "First.\n\n  Second.  \r\nThird.") == ["First.", "Second.", "Third."])
        #expect(PersonDetails.paragraphs(of: nil).isEmpty)
        #expect(PersonDetails.paragraphs(of: " \n ").isEmpty)
    }

    @Test func theCaptionIsTheRoleElseTheKindOfCreditInWords() {
        #expect(CastStrip.caption(role: "Barbra", type: "Actor") == "Barbra")
        #expect(CastStrip.caption(role: "Screenplay", type: "Writer") == "Screenplay")
        #expect(CastStrip.caption(role: "  ", type: "GuestStar") == "Guest Star")
        #expect(CastStrip.caption(role: nil, type: "Director") == "Director")
        #expect(CastStrip.caption(role: nil, type: nil) == nil)
    }

    @Test func aPersonRouteIsThePersonWhicheverCreditOpenedIt() throws {
        let people = try JellyfinClient.decoder.decode([Person].self, from: Data(#"""
        [
          { "Id": "romero", "Name": "George A. Romero", "Role": "Director", "Type": "Director" },
          { "Id": "romero", "Name": "George A. Romero", "Role": "Screenplay", "Type": "Writer" },
          { "Id": "russo", "Name": "John A. Russo", "Type": "Writer" }
        ]
        """#.utf8))
        #expect(ContentNavigationRoute.person(people[0]) == .person(people[1]))
        #expect(Set([ContentNavigationRoute.person(people[0]), .person(people[1])]).count == 1)
        #expect(ContentNavigationRoute.person(people[0]) != .person(people[2]))
    }

    @Test func theLibraryQueryAsksForMoviesAndSeriesCreditingThePersonNewestFirst() async throws {
        StubURLProtocol.register(host: "person-credits.test") { _ in
            let body = #"{"Items":[{"Id":"film","Name":"Night of the Living Dead","Type":"Movie"}],"TotalRecordCount":1}"#
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        let client = StubURLProtocol.makeJellyfinClient(host: "person-credits.test", deviceId: "person-credits-tests")

        let items = try await client.itemsCrediting(personId: "romero")

        #expect(items.map(\.id) == ["film"])
        let url = try #require(StubURLProtocol.requests(host: "person-credits.test").last?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(value("PersonIds") == "romero")
        #expect(value("IncludeItemTypes") == "Movie,Series")
        #expect(value("Recursive") == "true")
        #expect(value("SortOrder") == "Descending")
        #expect(value("SortBy")?.hasPrefix("PremiereDate") == true)
    }
}
