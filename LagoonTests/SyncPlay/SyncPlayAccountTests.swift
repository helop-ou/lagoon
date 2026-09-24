import Foundation
import Testing
@testable import Lagoon

@Suite("SyncPlay account isolation", .serialized)
@MainActor
struct SyncPlayAccountTests {
    @Test func pendingMembershipUsesItsOwnCredentialsWhenSharedClientChanges() async throws {
        let (client, store) = try makeStore()
        client.configure(serverURL: try #require(URL(string: "https://second.syncplay.test")))
        client.activateSession(token: "second-token", userId: "second-user")

        // SessionStore reconfigures the shared client before announcing the
        // switch; the old group's work must keep its old server and credentials.
        await store.refreshGroups()
        let outgoing = try #require(SyncPlayAccountFixture.lastRequest)
        #expect(outgoing.url?.host == "first.syncplay.test")
        #expect(outgoing.value(forHTTPHeaderField: "Authorization")?.contains("first-token") == true)

        store.configure(client: client, accountID: "second")
        await store.refreshGroups()
        let incoming = try #require(SyncPlayAccountFixture.lastRequest)
        #expect(incoming.url?.host == "second.syncplay.test")
        #expect(incoming.value(forHTTPHeaderField: "Authorization")?.contains("second-token") == true)
    }

    @Test func reauthenticationReplacesSnapshotEvenForTheSameAccount() async throws {
        let (client, store) = try makeStore()
        client.activateSession(token: "renewed-token", userId: "first-user")
        store.configure(client: client, accountID: "first")
        await store.refreshGroups()
        let request = try #require(SyncPlayAccountFixture.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("renewed-token") == true)
    }

    @Test(arguments: [true, false])
    func refusedWaitingTogglePreservesLastAcknowledgedState(requested: Bool) async throws {
        let (_, store) = try makeStore()
        joinFixture(store)
        if !requested { #expect(await store.setIgnoreWait(true)) }
        let previous = store.ignoresWait
        SyncPlayAccountFixture.respond(status: 403, forPrefix: "/SyncPlay/SetIgnoreWait")
        #expect(await store.setIgnoreWait(requested) == false)
        #expect(store.ignoresWait == previous)
        #expect(store.errorMessage != nil)
        #expect(store.notices.last?.notice == .requestFailed)
    }

    @Test(arguments: [200, 503])
    func missingQueueItemOffersRetryAndAttemptsToReleaseGroupWaiting(recoveryStatus: Int) async throws {
        let (_, store) = try makeStore()
        joinFixture(store)
        SyncPlayAccountFixture.respond(status: 404, forPrefix: "/Users/")
        SyncPlayAccountFixture.respond(status: recoveryStatus, forPrefix: "/SyncPlay/SetIgnoreWait")
        store.receive(ServerSocketMessage(
            messageType: "SyncPlayGroupUpdate", messageId: nil,
            payload: Data(#"{"GroupId":"group","Type":"PlayQueue","Data":{"Reason":"NewPlaylist","Playlist":[{"ItemId":"missing","PlaylistItemId":"entry"}],"PlayingItemIndex":0}}"#.utf8)
        ))
        let deadline = ContinuousClock.now + .seconds(2)
        while store.errorMessage?.contains("Rejoin") != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.errorMessage?.contains("Rejoin") == true)
        #expect(store.pendingPlayRequest == nil)
        #expect(store.ignoresWait == (recoveryStatus == 200))
        #expect(SyncPlayAccountFixture.lastRequest?.url?.path == "/SyncPlay/SetIgnoreWait")
    }

    private func joinFixture(_ store: SyncPlayStore) {
        store.receive(ServerSocketMessage(
            messageType: "SyncPlayGroupUpdate", messageId: nil,
            payload: Data(#"{"GroupId":"group","Type":"GroupJoined","Data":{"GroupId":"group","GroupName":"Room"}}"#.utf8)
        ))
    }

    private func makeStore() throws -> (JellyfinClient, SyncPlayStore) {
        SyncPlayAccountFixture.reset()
        StubURLProtocol.register(host: "first.syncplay.test", handler: SyncPlayAccountFixture.respond)
        StubURLProtocol.register(host: "second.syncplay.test", handler: SyncPlayAccountFixture.respond)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "first.syncplay.test", deviceId: "syncplay-tests", token: "first-token", userId: "first-user"
        )
        let store = SyncPlayStore()
        store.configure(client: client, accountID: "first")
        return (client, store)
    }
}

/// Fixture state for `SyncPlayAccountTests`, spanning both the "first" and
/// "second" syncplay hosts so `lastRequest` reflects whichever host a test
/// last exercised, matching the original single-recorder behavior.
private enum SyncPlayAccountFixture {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: URLRequest?
    private nonisolated(unsafe) static var statuses: [String: Int] = [:]

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = nil
        statuses = [:]
    }

    static func respond(status: Int, forPrefix prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        statuses[prefix] = status
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func respond(to request: URLRequest) throws -> (Int, [String: String], Data) {
        lock.lock()
        recorded = request
        let status = statuses.first { request.url?.path.hasPrefix($0.key) == true }?.value ?? 200
        lock.unlock()
        return (status, [:], Data("[]".utf8))
    }
}
