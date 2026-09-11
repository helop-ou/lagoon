import Foundation
import Testing
@testable import Lagoon

@Suite("Jellyfin provider lookup", .serialized)
struct JellyfinProviderLookupTests {
    @Test func usesJellyfinProviderKeyAndReturnsExactTMDBMatch() async throws {
        let client = makeClient(responseProviderID: "123")

        let item = try await client.item(tmdbID: 123, mediaType: .movie)

        #expect(item?.id == "matching-item")
        let url = try #require(JellyfinProviderLookupURLProtocol.lastURL)
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
        JellyfinProviderLookupURLProtocol.reset(responseProviderID: responseProviderID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JellyfinProviderLookupURLProtocol.self]
        let client = JellyfinClient(deviceId: "provider-lookup-tests", sessionConfiguration: configuration)
        client.configure(serverURL: URL(string: "https://jellyfin.test")!)
        client.activateSession(token: "token", userId: "user")
        return client
    }
}

private nonisolated final class JellyfinProviderLookupURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedURL: URL?
    private nonisolated(unsafe) static var providerID = ""

    static var lastURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedURL
    }

    static func reset(responseProviderID: String) {
        lock.lock()
        recordedURL = nil
        providerID = responseProviderID
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "jellyfin.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        Self.lock.lock()
        Self.recordedURL = url
        let responseProviderID = Self.providerID
        Self.lock.unlock()

        let body = #"{"Items":[{"Id":"matching-item","Name":"Match","Type":"Movie","ProviderIds":{"Tmdb":"\#(responseProviderID)"}}],"TotalRecordCount":1}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
