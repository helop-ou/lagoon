import Foundation
import Testing
@testable import Lagoon

@Suite("Jellyfin provider lookup", .serialized)
struct JellyfinProviderLookupTests {
    @Test func usesJellyfinProviderKeyAndReturnsExactTMDBMatch() async throws {
        let client = makeClient(responseProviderID: "123")

        let item = try await client.item(tmdbID: 123, mediaType: .movie)

        #expect(item?.id == "matching-item")
        let url = try #require(StubURLProtocol.requests(host: "jellyfin.test").last?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "AnyProviderIdEquals" })?.value == "Tmdb.123")
        #expect(components.queryItems?.first(where: { $0.name == "IncludeItemTypes" })?.value == "Movie")
    }

    @Test func rejectsAnUnrelatedItemIfServerIgnoresProviderFilter() async throws {
        let client = makeClient(responseProviderID: "999")

        let item = try await client.item(tmdbID: 123, mediaType: .movie)

        #expect(item == nil)
    }

    private func makeClient(responseProviderID: String) -> JellyfinClient {
        StubURLProtocol.register(host: "jellyfin.test") { _ in
            let body = #"{"Items":[{"Id":"matching-item","Name":"Match","Type":"Movie","ProviderIds":{"Tmdb":"\#(responseProviderID)"}}],"TotalRecordCount":1}"#
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        return StubURLProtocol.makeJellyfinClient(host: "jellyfin.test", deviceId: "provider-lookup-tests")
    }
}
