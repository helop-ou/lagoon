import Foundation
import Testing
@testable import Lagoon

/// The store's socket boundary: which commands it takes, where a rejoin
/// puts the viewer, and what leaving the group clears.
@Suite("SyncPlay store", .serialized)
@MainActor
struct SyncPlayStoreTests {
    static let host = "store.syncplay.test"

    /// Joined, with the group's queue loaded and waiting for a player.
    private func joinedStore() async throws -> SyncPlayStore {
        StubURLProtocol.register(host: Self.host) { request in
            if request.url?.path.contains("/Items/") == true {
                return (200, [:], Data(#"{"Id":"film","Name":"Film","Type":"Movie"}"#.utf8))
            }
            return (204, [:], Data())
        }
        let store = SyncPlayStore()
        store.configure(
            client: StubURLProtocol.makeJellyfinClient(host: Self.host, deviceId: "syncplay-store-tests"),
            accountID: "account"
        )
        store.receive(Self.message("SyncPlayGroupUpdate", #"{"GroupId":"group","Type":"GroupJoined","Data":{"GroupId":"group","GroupName":"Room"}}"#))
        store.receive(Self.message("SyncPlayGroupUpdate", """
        {"GroupId":"group","Type":"PlayQueue","Data":{"Reason":"NewPlaylist",
         "Playlist":[{"ItemId":"film","PlaylistItemId":"entry"}],"PlayingItemIndex":0,"StartPositionTicks":50000000}}
        """))
        try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(10)) {
            store.pendingPlayRequest != nil
        }
        #expect(store.pendingPlayRequest?.startSeconds == 5)
        return store
    }

    private static func message(_ type: String, _ payload: String) -> ServerSocketMessage {
        ServerSocketMessage(messageType: type, messageId: nil, payload: Data(payload.utf8))
    }

    private static func command(
        _ kind: String,
        positionTicks: Int64,
        when: String,
        playlistItemId: String = "entry"
    ) -> ServerSocketMessage {
        message("SyncPlayCommand", """
        {"GroupId":"group","PlaylistItemId":"\(playlistItemId)","When":"\(when)",
         "PositionTicks":\(positionTicks),"Command":"\(kind)","EmittedAt":"\(when)"}
        """)
    }

    private static let instant = "2026-09-14T11:44:21.0000000Z"

    private func lastIgnoreWaitBody() throws -> Data? {
        try #require(StubURLProtocol.requests(host: Self.host).last { $0.url?.path == "/SyncPlay/SetIgnoreWait" }).httpBody
    }

    // MARK: - Commands

    /// The instant is what every member acts on, so a command without one,
    /// or for an item the group moved past, is never taken.
    @Test func onlyACommandWithAnInstantForTheCurrentItemIsTaken() async throws {
        let store = try await joinedStore()
        store.receive(Self.command("Pause", positionTicks: 420_000_000, when: ""))
        #expect(store.session.lastCommand == nil)
        store.receive(Self.command("Pause", positionTicks: 420_000_000, when: Self.instant, playlistItemId: "elsewhere"))
        #expect(store.session.lastCommand == nil)
        store.receive(Self.command("Pause", positionTicks: 420_000_000, when: Self.instant))
        #expect(store.session.lastCommand?.command == .pause)
        #expect(store.session.lastCommand?.positionTicks == 420_000_000)
    }

    // MARK: - Rejoining

    /// After a pause the group is still, so a rejoin opens exactly there,
    /// not at the queue's start position.
    @Test func rejoiningAPausedGroupOpensWhereItPaused() async throws {
        let store = try await joinedStore()
        store.pendingPlayRequest = nil
        #expect(await store.setIgnoreWait(true))
        store.receive(Self.command("Pause", positionTicks: 420_000_000, when: Self.instant))

        await store.rejoinPlayback()

        let request = try #require(store.pendingPlayRequest)
        #expect(request.startSeconds == 42)
        #expect(request.playlistItemId == "entry")
        #expect(request.media.id == "film")
        // Back in the group's readiness accounting, as the server acknowledged.
        #expect(!store.ignoresWait)
        let body = try #require(try lastIgnoreWaitBody())
        #expect(try JSONSerialization.jsonObject(with: body) as? NSDictionary == ["IgnoreWait": false])
    }

    /// A running group has moved on since its Unpause.
    @Test func rejoiningARunningGroupOpensWhereItIsNow() async throws {
        let store = try await joinedStore()
        store.pendingPlayRequest = nil
        let tenSecondsAgo = JellyfinTimestamp.string(Date().timeIntervalSince1970 - 10)
        store.receive(Self.command("Unpause", positionTicks: 300_000_000, when: tenSecondsAgo))

        await store.rejoinPlayback()

        // 30 s plus the ten that have passed; no server clock, so local time.
        let start = try #require(store.pendingPlayRequest?.startSeconds)
        #expect(start >= 40 && start < 42)
    }

    // MARK: - Leaving

    /// The server ended this membership: nothing of it may linger to open a
    /// player or hold this member out of the next group's waiting.
    @Test func leavingTheGroupClearsWhatItLeftBehind() async throws {
        let store = try await joinedStore()
        #expect(await store.setIgnoreWait(true))
        #expect(store.ignoresWait)

        store.receive(Self.message("SyncPlayGroupUpdate", #"{"GroupId":"group","Type":"GroupLeft","Data":"group"}"#))

        #expect(!store.isJoined)
        #expect(store.pendingPlayRequest == nil)
        #expect(!store.ignoresWait)
        #expect(!store.isPlayerOpen)
        #expect(store.notices.last?.notice == .left(.leftGroup))
    }
}
