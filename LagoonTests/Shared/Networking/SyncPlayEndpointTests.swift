import Foundation
import Testing
@testable import Lagoon

/// What each SyncPlay request sends: the route, the method and the
/// PascalCase body Jellyfin binds, since a misnamed field is ignored without
/// an error and the group simply never hears this member.
@Suite("SyncPlay endpoints", .serialized)
@MainActor
struct SyncPlayEndpointTests {
    static let host = "syncplay-endpoints.test"

    private func makeClient() -> JellyfinClient {
        StubURLProtocol.register(host: Self.host) { _ in (204, [:], Data()) }
        return StubURLProtocol.makeJellyfinClient(host: Self.host, deviceId: "syncplay-endpoint-tests")
    }

    /// The method, path and parsed body of the last request.
    private func sent() throws -> (method: String?, path: String?, body: NSDictionary?) {
        let request = try #require(StubURLProtocol.requests(host: Self.host).last)
        let body = try request.httpBody.flatMap { $0.isEmpty ? nil : try JSONSerialization.jsonObject(with: $0) as? NSDictionary }
        return (request.httpMethod, request.url?.path, body)
    }

    private static let report = SyncPlayReadinessReport(
        when: "2026-09-14T11:44:21.3560439Z",
        positionTicks: 600_000_000,
        isPlaying: true,
        playlistItemId: "8a3228756d3e439f9b8cd5bdbfe8deb6"
    )

    private static let reportBody: NSDictionary = [
        "When": "2026-09-14T11:44:21.3560439Z",
        "PositionTicks": 600_000_000,
        "IsPlaying": true,
        "PlaylistItemId": "8a3228756d3e439f9b8cd5bdbfe8deb6",
    ]

    @Test func readinessReportsGoToTheirOwnRoutes() async throws {
        let client = makeClient()
        try await client.syncPlayReportReady(Self.report)
        var request = try sent()
        #expect(request.method == "POST")
        #expect(request.path == "/SyncPlay/Ready")
        #expect(request.body == Self.reportBody)

        try await client.syncPlayReportBuffering(Self.report)
        request = try sent()
        #expect(request.path == "/SyncPlay/Buffering")
        #expect(request.body == Self.reportBody)
    }

    @Test func pingAndIgnoreWaitCarryTheirValues() async throws {
        let client = makeClient()
        try await client.syncPlayPing(milliseconds: 42)
        var request = try sent()
        #expect(request.path == "/SyncPlay/Ping")
        #expect(request.body == ["Ping": 42])

        try await client.syncPlaySetIgnoreWait(true)
        request = try sent()
        #expect(request.path == "/SyncPlay/SetIgnoreWait")
        #expect(request.body == ["IgnoreWait": true])
    }

    @Test func membershipRequests() async throws {
        let client = makeClient()
        try await client.syncPlayCreateGroup(named: "Film night")
        var request = try sent()
        #expect(request.path == "/SyncPlay/New")
        #expect(request.body == ["GroupName": "Film night"])

        try await client.syncPlayJoin(groupId: "ea9615382d214f9c9313c26fbd3bad89")
        request = try sent()
        #expect(request.path == "/SyncPlay/Join")
        #expect(request.body == ["GroupId": "ea9615382d214f9c9313c26fbd3bad89"])

        try await client.syncPlayLeave()
        request = try sent()
        #expect(request.method == "POST")
        #expect(request.path == "/SyncPlay/Leave")
        #expect(request.body == nil)
    }

    @Test func transportRequests() async throws {
        let client = makeClient()
        try await client.syncPlaySetQueue(itemIds: ["a1", "b2"], playingIndex: 1, startPositionTicks: 50)
        var request = try sent()
        #expect(request.path == "/SyncPlay/SetNewQueue")
        #expect(request.body == ["PlayingQueue": ["a1", "b2"], "PlayingItemPosition": 1, "StartPositionTicks": 50])

        try await client.syncPlaySeek(positionTicks: 1_200)
        request = try sent()
        #expect(request.path == "/SyncPlay/Seek")
        #expect(request.body == ["PositionTicks": 1_200])

        try await client.syncPlayNextItem(playlistItemId: "p2")
        request = try sent()
        #expect(request.path == "/SyncPlay/NextItem")
        #expect(request.body == ["PlaylistItemId": "p2"])

        try await client.syncPlayUnpause()
        request = try sent()
        #expect(request.path == "/SyncPlay/Unpause")
        #expect(request.body == nil)

        try await client.syncPlayPause()
        request = try sent()
        #expect(request.path == "/SyncPlay/Pause")
        #expect(request.body == nil)
    }
}
