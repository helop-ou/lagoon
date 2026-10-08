import Foundation
import Testing
@testable import Lagoon

@Suite("Session store accounts", .serialized)
@MainActor
struct SessionStoreTests {
    // MARK: - Library cache

    @Test func librariesAreCachedPerAccount() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let movies = try LibraryTab(JellyfinClient.decoder.decode(
            MediaItem.self, from: Data(#"{"Id":"movies","Name":"Movies","CollectionType":"movies"}"#.utf8)
        ))
        store.cacheLibraries([movies])
        #expect(store.cachedLibraries() == [movies])

        store.switchTo(fixture.b)
        #expect(store.cachedLibraries() == [])

        store.switchTo(fixture.a)
        #expect(store.cachedLibraries() == [movies])
    }

    // MARK: - The picker's resume line

    @Test func aUsableProfileIsAskedWithItsOwnToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let item = await store.latestResume(for: fixture.b)
        #expect(item?.id == "resume-b")
        let resume = try #require(ProfileProtocol.requests.first { $0.url?.path.hasSuffix("Items/Resume") == true })
        #expect(resume.value(forHTTPHeaderField: "Authorization")?.contains(#"Token="token-b""#) == true)
    }

    @Test func aProfileWithoutASignInIsNeverAsked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try fixture.credentials.delete(fixture.b.keychainAccount)
        #expect(await store.latestResume(for: fixture.b) == nil)
        #expect(fixture.resumeRequests.isEmpty)
    }

    @Test func anExpiredProfileIsNeverAsked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set([fixture.b.id], forKey: "session.expiredAccountIds")
        let store = fixture.store()
        #expect(await store.latestResume(for: fixture.b) == nil)
        #expect(fixture.resumeRequests.isEmpty)
    }

    @Test func aProfileBeingRemovedIsNeverAsked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        AccountLocalData(defaults: fixture.defaults, credentials: fixture.credentials).beginRemoval(accountID: fixture.b.id)
        #expect(await store.latestResume(for: fixture.b) == nil)
        #expect(fixture.resumeRequests.isEmpty)
    }

    // MARK: - Profile refresh

    @Test func aChangedNameOrPictureReplacesTheStoredRecord() throws {
        let account = StoredAccount(serverURL: URL(string: "https://jellyfin.test")!, serverName: "Server",
                                    userId: "user", userName: "Old", primaryImageTag: "tag-1")
        let renamed = SessionStore.refreshedProfile(of: account, from: try user(#"{"Id":"user","Name":"New","PrimaryImageTag":"tag-1"}"#))
        #expect(renamed?.userName == "New")
        #expect(renamed?.primaryImageTag == "tag-1")
        let repictured = SessionStore.refreshedProfile(of: account, from: try user(#"{"Id":"user","PrimaryImageTag":"tag-2"}"#))
        #expect(repictured?.userName == "Old")
        #expect(repictured?.primaryImageTag == "tag-2")
        #expect(SessionStore.refreshedProfile(of: account, from: try user(#"{"Id":"user","Name":"Old","PrimaryImageTag":"tag-1"}"#)) == nil)
    }

    @Test func aProfileForAnotherUserIsIgnored() throws {
        let account = StoredAccount(serverURL: URL(string: "https://jellyfin.test")!, serverName: "Server",
                                    userId: "user", userName: "Old")
        #expect(SessionStore.refreshedProfile(of: account, from: try user(#"{"Id":"someone-else","Name":"Intruder"}"#)) == nil)
    }

    @Test func aLateProfileReadCannotRenameTheNextAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // A's profile read waits; B's answers at once.
        ProfileProtocol.hold(token: "token-a")
        let store = fixture.store()
        let lateRead = try #require(store.profileRefresh)
        try await ProfileProtocol.waitUntilHeld()

        store.switchTo(fixture.b)
        await store.profileRefresh?.value
        #expect(store.userName == "Viewer B renamed")
        ProfileProtocol.releaseHeld()
        await lateRead.value

        #expect(store.activeAccount?.id == fixture.b.id)
        #expect(store.userName == "Viewer B renamed")
        #expect(store.accounts.first { $0.id == fixture.a.id }?.userName == "Viewer A")
    }

    // MARK: - Seerr address

    @Test func aSeerrAddressStaysWhileAnotherProfileUsesTheServer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seerrKey = AccountLocalData.seerrServerKey(fixture.a)
        fixture.defaults.set("https://seerr.test", forKey: seerrKey)
        let store = fixture.store()

        try store.remove(fixture.sameServerAsA)
        #expect(fixture.defaults.string(forKey: seerrKey) == "https://seerr.test")

        try store.remove(fixture.a)
        #expect(fixture.defaults.string(forKey: seerrKey) == nil)
    }

    private func user(_ json: String) throws -> UserDto {
        try JellyfinClient.decoder.decode(UserDto.self, from: Data(json.utf8))
    }

    private final class Fixture {
        let suite = "SessionStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let credentials = MemoryAccountCredentials()
        let a = StoredAccount(serverURL: URL(string: "https://a.session.test")!, serverName: "A", userId: "user-a", userName: "Viewer A")
        let b = StoredAccount(serverURL: URL(string: "https://b.session.test")!, serverName: "B", userId: "user-b", userName: "Viewer B")
        let sameServerAsA = StoredAccount(serverURL: URL(string: "https://a.session.test")!, serverName: "A", userId: "user-c", userName: "Viewer C")

        init() throws {
            ProfileProtocol.reset()
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(try JSONEncoder().encode([a, b, sameServerAsA]), forKey: "accounts")
            defaults.set(a.id, forKey: "session.activeAccountId")
            try credentials.set("token-a", for: a.keychainAccount)
            try credentials.set("token-b", for: b.keychainAccount)
            try credentials.set("token-c", for: sameServerAsA.keychainAccount)
        }

        var resumeRequests: [URLRequest] {
            ProfileProtocol.requests.filter { $0.url?.path.hasSuffix("Items/Resume") == true }
        }

        func store() -> SessionStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProfileProtocol.self]
            return SessionStore(defaults: defaults, sessionConfiguration: configuration, credentials: credentials,
                                seerrClient: SeerrClient(session: URLSession(configuration: configuration)))
        }

        func cleanUp() {
            ProfileProtocol.releaseHeld()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

/// Answers by the token a request carries: each account sees its own
/// profile and resume item, and one account's requests can be held.
private nonisolated final class ProfileProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [URLRequest] = []
    private nonisolated(unsafe) static var heldToken: String?
    private nonisolated(unsafe) static var held: [ProfileProtocol] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = []; heldToken = nil; held = [] } }
    static func hold(token: String) { lock.withLock { heldToken = token } }

    static func waitUntilHeld() async throws {
        try await Polling.until(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
            lock.withLock { !held.isEmpty }
        }
        guard lock.withLock({ !held.isEmpty }) else { throw URLError(.timedOut) }
    }

    static func releaseHeld() {
        let pending = lock.withLock { let result = held; held = []; heldToken = nil; return result }
        for request in pending { request.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let shouldHold = Self.lock.withLock {
            Self.recorded.append(request)
            guard let token = Self.heldToken, Self.token(of: request) == token else { return false }
            Self.held.append(self)
            return true
        }
        if !shouldHold { respond() }
    }

    override func stopLoading() {}

    private static func token(of request: URLRequest) -> String? {
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        return ["token-a", "token-b", "token-c"].first { header.contains("Token=\"\($0)\"") }
    }

    private func respond() {
        guard let url = request.url else { return }
        let token = Self.token(of: request)
        let account = token.map { String($0.dropFirst("token-".count)) } ?? "none"
        let body: String
        if url.path.hasSuffix("Users/Me") {
            // Every reply renames, so an applied one is visible.
            let name = account == "a" ? "Viewer A renamed" : "Viewer B renamed"
            body = "{\"Id\":\"user-\(account)\",\"Name\":\"\(name)\"}"
        } else if url.path.hasSuffix("Items/Resume") {
            body = "{\"Items\":[{\"Id\":\"resume-\(account)\",\"Type\":\"Movie\"}],\"TotalRecordCount\":1}"
        } else {
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
