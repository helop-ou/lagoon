import Foundation
import Testing
@testable import Lagoon

/// Serialized: the fixture's script is shared state.
@Suite("Seerr title page refresh", .serialized)
@MainActor
struct SeerrMediaDetailModelTests {
    @Test func aPollReadsTheLiveStateAndLeavesRecommendationsAlone() async throws {
        let clients = makeClients()
        let model = SeerrMediaDetailModel(mediaID: 603, mediaType: .movie)

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)
        #expect(model.details?.mediaInfo?.availability == .processing)
        // People are not titles and never reach the rail.
        #expect(model.recommendations.map(\.id) == [1, 2])

        SeerrMediaFixture.update {
            $0.details = Fixtures.availableDetails
            $0.recommendations = Fixtures.otherRecommendations
            $0.paths = []
        }
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(model.details?.mediaInfo?.availability == .available)
        #expect(model.jellyfinItem?.id == "jellyfin-arrival")
        #expect(model.recommendations.map(\.id) == [1, 2])
        #expect(SeerrMediaFixture.script.paths == ["/api/v1/movie/603", "/Users/user/Items/jellyfin-arrival"])
    }

    @Test func aFailedPollKeepsTheLastGoodDetails() async throws {
        let clients = makeClients()
        let model = SeerrMediaDetailModel(mediaID: 603, mediaType: .movie)
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)

        SeerrMediaFixture.update { $0.isFailing = true }
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(model.errorMessage == nil)
        #expect(model.details?.displayTitle == "Arrival")
        #expect(model.details?.mediaInfo?.availability == .processing)
        #expect(model.recommendations.map(\.id) == [1, 2])
    }

    @Test func aFirstLoadThatFailsReachesTheViewer() async throws {
        let clients = makeClients()
        let model = SeerrMediaDetailModel(mediaID: 603, mediaType: .movie)
        SeerrMediaFixture.update { $0.isFailing = true }

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)

        #expect(model.details == nil)
        #expect(model.errorMessage != nil)
        #expect(!model.isLoading)
    }

    private func makeClients() -> (seerr: SeerrClient, jellyfin: JellyfinClient) {
        SeerrMediaFixture.update {
            $0 = SeerrMediaFixture.Script(details: Fixtures.processingDetails, recommendations: Fixtures.recommendations)
        }
        StubURLProtocol.register(host: "seerr.media.test", handler: SeerrMediaFixture.respond)
        StubURLProtocol.register(host: "jellyfin.media.test", handler: SeerrMediaFixture.respond)
        let seerr = SeerrClient(session: URLSession(configuration: StubURLProtocol.configuration()), requestTimeout: 5)
        seerr.configure(serverURL: URL(string: "https://seerr.media.test")!)
        seerr.setSessionCookie("session")
        let jellyfin = StubURLProtocol.makeJellyfinClient(host: "jellyfin.media.test", deviceId: "seerr-media-tests")
        return (seerr, jellyfin)
    }

    private enum Fixtures {
        static let processingDetails =
            #"{"id":603,"title":"Arrival","mediaInfo":{"id":8,"tmdbId":603,"status":3}}"#
        static let availableDetails =
            #"{"id":603,"title":"Arrival","mediaInfo":{"id":8,"tmdbId":603,"status":5,"jellyfinMediaId":"jellyfin-arrival"}}"#
        static let recommendations =
            #"{"page":1,"totalPages":1,"totalResults":3,"results":[{"id":1,"mediaType":"movie"},{"id":2,"mediaType":"tv"},{"id":3,"mediaType":"person"}]}"#
        static let otherRecommendations =
            #"{"page":1,"totalPages":1,"totalResults":1,"results":[{"id":9,"mediaType":"movie"}]}"#
    }
}

/// Serves one Seerr title, its recommendations and its Jellyfin item across
/// both hosts, recording paths in call order; can go dark on command.
private enum SeerrMediaFixture {
    struct Script {
        var details: String
        var recommendations: String
        var isFailing = false
        var paths: [String] = []
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var current = Script(details: "", recommendations: "")

    static var script: Script { lock.withLock { current } }

    static func update(_ change: (inout Script) -> Void) {
        lock.withLock { change(&current) }
    }

    static func respond(to request: URLRequest) throws -> (Int, [String: String], Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let (body, isFailing) = lock.withLock { () -> (String?, Bool) in
            current.paths.append(url.path)
            let body: String? = switch url.path {
            case "/api/v1/movie/603": current.details
            case "/api/v1/movie/603/recommendations": current.recommendations
            case "/Users/user/Items/jellyfin-arrival": #"{"Id":"jellyfin-arrival","Name":"Arrival","Type":"Movie"}"#
            default: nil
            }
            return (body, current.isFailing)
        }
        if isFailing { throw URLError(.notConnectedToInternet) }
        guard let body else { throw URLError(.badServerResponse) }
        return (200, ["Content-Type": "application/json"], Data(body.utf8))
    }
}
