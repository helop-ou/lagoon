import Foundation
import Testing
@testable import Lagoon

/// With "Display missing episodes" on, Jellyfin lists episodes it has no file
/// for. Every episode lookup asks it to leave them out.
@Suite("Episodes with a file", .serialized)
@MainActor
struct EpisodesWithAFileTests {
    private static let page = #"{"Items":[{"Id":"e1","Name":"e1","Type":"Episode","SeriesId":"s"},{"Id":"e2","Name":"e2","Type":"Episode","SeriesId":"s"},{"Id":"e3","Name":"e3","Type":"Episode","SeriesId":"s"}]}"#

    @Test func theSeasonListLeavesOutMissingEpisodes() async throws {
        let query = try await query { client, _ in
            _ = try await client.episodes(seriesId: "s", seasonId: "season")
        }
        #expect(query.contains(URLQueryItem(name: "IsMissing", value: "false")))
    }

    @Test func theNextEpisodeIsTheNextWithAFile() async throws {
        let query = try await query { client, episode in
            _ = try await client.episodeAfter(episode)
        }
        #expect(query.contains(URLQueryItem(name: "IsMissing", value: "false")))
    }

    @Test func thePreviousEpisodeIsTheLastWithAFile() async throws {
        let query = try await query { client, episode in
            _ = try await client.episodeBefore(episode)
        }
        #expect(query.contains(URLQueryItem(name: "IsMissing", value: "false")))
    }

    /// The query of the one request the lookup sends.
    private func query(
        _ lookup: (JellyfinClient, MediaItem) async throws -> Void,
        function: String = #function
    ) async throws -> [URLQueryItem] {
        let host = "episodes-with-a-file-\(abs(function.hashValue)).test"
        StubURLProtocol.register(host: host) { _ in
            (200, ["Content-Type": "application/json"], Data(Self.page.utf8))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "episodes-with-a-file-tests")
        let episode = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"e2","Name":"e2","Type":"Episode","SeriesId":"s"}"#.utf8)
        )
        try await lookup(client, episode)
        let request = try #require(StubURLProtocol.requests(host: host).first?.url)
        #expect(request.path.hasSuffix("Shows/s/Episodes"))
        return URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }
}
