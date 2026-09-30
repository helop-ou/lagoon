import Foundation
import Testing
@testable import Lagoon

/// Custom headers for a server behind a forward-auth proxy: what may be
/// stored, where they are sent, and that they never follow a request away
/// from their host.
@Suite("Server proxy headers")
struct ServerHeaderTests {
    private func store(_ headers: [CustomHTTPHeader] = [], host: String = "jellyfin.example.com") throws -> ServerHeaderStore {
        let store = ServerHeaderStore(credentials: MemoryAccountCredentials())
        if !headers.isEmpty { try store.setHeaders(headers, forHost: host) }
        return store
    }

    private let token = [
        CustomHTTPHeader(name: "CF-Access-Client-Id", value: "id.access"),
        CustomHTTPHeader(name: "CF-Access-Client-Secret", value: "secret"),
    ]

    @Test func blankRowsAreDroppedAndBadOnesNamed() throws {
        #expect(try CustomHTTPHeader.validated([CustomHTTPHeader(), CustomHTTPHeader(name: " X-Token ", value: " a ")]).get()
            .map { "\($0.name)=\($0.value)" } == ["X-Token=a"])
        #expect(CustomHTTPHeader.validated([CustomHTTPHeader(name: "Bad Name", value: "x")])
            == .failure(.invalidName("Bad Name")))
        #expect(CustomHTTPHeader.validated([CustomHTTPHeader(name: "authorization", value: "x")])
            == .failure(.reservedName("authorization")))
        #expect(CustomHTTPHeader.validated([CustomHTTPHeader(name: "X-A", value: "1"), CustomHTTPHeader(name: "x-a", value: "2")])
            == .failure(.duplicateName("x-a")))
        #expect(CustomHTTPHeader.validated([CustomHTTPHeader(name: "X-A", value: " ")])
            == .failure(.missingValue("X-A")))
        #expect(CustomHTTPHeader.validated([CustomHTTPHeader(name: "X-A", value: "a\r\nX-B: b")])
            == .failure(.invalidValue("X-A")))
        // URLSession owns these, and Jellyfin reads the last three as its token.
        for name in ["Proxy-Authorization", "WWW-Authenticate", "Sec-WebSocket-Key", "X-Emby-Token", "X-MediaBrowser-Token"] {
            #expect(CustomHTTPHeader.validated([CustomHTTPHeader(name: name, value: "x")]) == .failure(.reservedName(name)))
        }
    }

    @Test func theSocketCarriesTheHeadersOverWSSOnly() throws {
        let store = try store(token)
        let secure = URLRequest(url: URL(string: "wss://jellyfin.example.com/socket?api_key=t")!).withServerHeaders(store)
        #expect(secure.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        let plain = URLRequest(url: URL(string: "ws://jellyfin.example.com/socket?api_key=t")!).withServerHeaders(store)
        #expect(plain.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func headersGoToTheirHostOverHTTPSOnly() throws {
        let store = try store(token)
        var request = URLRequest(url: URL(string: "https://JELLYFIN.example.com:8920/Items")!)
        store.apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")

        var plain = URLRequest(url: URL(string: "http://jellyfin.example.com/Items")!)
        store.apply(to: &plain)
        #expect(plain.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)

        var elsewhere = URLRequest(url: URL(string: "https://images.example.net/a.jpg")!)
        store.apply(to: &elsewhere)
        #expect(elsewhere.allHTTPHeaderFields?.isEmpty ?? true)
    }

    @Test func aHeaderTheRequestAlreadySetsIsNotReplaced() throws {
        let store = try store([CustomHTTPHeader(name: "X-Client", value: "proxy")])
        var request = URLRequest(url: URL(string: "https://jellyfin.example.com/")!)
        request.setValue("app", forHTTPHeaderField: "X-Client")
        store.apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-Client") == "app")
    }

    @Test func aRedirectKeepsTheHeadersOnlyOnTheSameHostOverHTTPS() throws {
        let store = try store(token)
        let original = URL(string: "https://jellyfin.example.com/Items")!
        let sent = URLRequest(url: original).withServerHeaders(store)

        var sameHost = sent
        sameHost.url = URL(string: "https://jellyfin.example.com/Items/1")!
        #expect(store.redirected(sameHost, from: original).value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")

        var login = sent
        login.url = URL(string: "https://team.cloudflareaccess.com/login")!
        #expect(store.redirected(login, from: original).value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(store.redirected(login, from: original).value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)

        var downgraded = sent
        downgraded.url = URL(string: "http://jellyfin.example.com/Items")!
        #expect(store.redirected(downgraded, from: original).value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func anUpgradeToHTTPSOnTheSameHostGainsTheHeaders() throws {
        // "Always Use HTTPS": the first hop was plain HTTP, so it carried none.
        let store = try store(token)
        let original = URL(string: "http://jellyfin.example.com/System/Info/Public")!
        var upgraded = URLRequest(url: original).withServerHeaders(store)
        #expect(upgraded.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        upgraded.url = URL(string: "https://jellyfin.example.com/System/Info/Public")!
        #expect(store.redirected(upgraded, from: original).value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
    }

    @Test func storedHeadersSurviveANewStoreAndCanBeRemoved() throws {
        let credentials = MemoryAccountCredentials()
        try ServerHeaderStore(credentials: credentials).setHeaders(token, forHost: "Seerr.Example.com")
        // A relaunch reads them back from the keychain.
        let reopened = ServerHeaderStore(credentials: credentials)
        #expect(reopened.headers(forHost: "seerr.example.com").map(\.name) == token.map(\.name))
        #expect(credentials.string(for: ServerHeaderStore.keychainAccount(forHost: "seerr.example.com")) != nil)

        reopened.removeHeaders(forHost: "seerr.example.com")
        #expect(reopened.headers(forHost: "seerr.example.com").isEmpty)
        #expect(credentials.string(for: ServerHeaderStore.keychainAccount(forHost: "seerr.example.com")) == nil)
    }

    @Test func stagingForAConnectionCanBeUndoneWhenItFails() throws {
        let store = try store()
        let undo = try store.stage(token, for: "jellyfin.example.com", service: .jellyfin)
        #expect(store.headers(forHost: "jellyfin.example.com").count == 2)
        undo()
        #expect(store.headers(forHost: "jellyfin.example.com").isEmpty)

        // Nothing entered changes nothing.
        let none = try store.stage([CustomHTTPHeader()], for: "jellyfin.example.com", service: .jellyfin)
        none()
        #expect(store.headers(forHost: "jellyfin.example.com").isEmpty)

        #expect(throws: CustomHTTPHeader.Problem.reservedName("Cookie")) {
            try store.stage([CustomHTTPHeader(name: "Cookie", value: "x")], for: "jellyfin.example.com", service: .jellyfin)
        }
    }
}

/// A proxy's headers are a credential, so they leave the keychain once no
/// account's server and no Seerr saved for one is on their host.
@Suite("Server proxy header lifecycle", .serialized)
@MainActor
struct ServerHeaderLifecycleTests {
    private let token = [CustomHTTPHeader(name: "CF-Access-Client-Secret", value: "secret")]
    private let first = StoredAccount(serverURL: URL(string: "https://jf.lifecycle.test")!, serverName: "JF",
                                      userId: "one", userName: "One")
    private let second = StoredAccount(serverURL: URL(string: "https://jf.lifecycle.test")!, serverName: "JF",
                                       userId: "two", userName: "Two")
    private let other = StoredAccount(serverURL: URL(string: "https://other.lifecycle.test")!, serverName: "Other",
                                      userId: "three", userName: "Three")

    private final class Fixture {
        let suite = "ServerHeaderLifecycleTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let headers = ServerHeaderStore(credentials: MemoryAccountCredentials())

        init(accounts: [StoredAccount]) throws {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(try JSONEncoder().encode(accounts), forKey: "accounts")
        }

        func store(draft: Bool = false) -> SessionStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineProtocol.self]
            return SessionStore(
                accountDraft: draft, defaults: defaults, sessionConfiguration: configuration,
                credentials: MemoryAccountCredentials(),
                seerrClient: SeerrClient(session: URLSession(configuration: configuration)),
                serverHeaders: headers,
                publicInfo: { _ in PublicSystemInfo(serverName: "Fixture", version: "10.11.0", id: "fixture") }
            )
        }

        func saveSeerr(_ address: String, for account: StoredAccount) {
            defaults.set(address, forKey: AccountLocalData.seerrServerKey(account))
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func hostsInUseAreEveryAccountsServerAndItsSeerr() throws {
        let fixture = try Fixture(accounts: [first, other])
        fixture.saveSeerr("https://Seerr.Lifecycle.test:5055", for: first)
        #expect(SessionStore.serverHostsInUse(accounts: [first, other], defaults: fixture.defaults)
            == ["jf.lifecycle.test", "other.lifecycle.test", "seerr.lifecycle.test"])
    }

    @Test func removingTheLastAccountOnAHostTakesItsAndItsSeerrsHeaders() throws {
        let fixture = try Fixture(accounts: [first, second])
        fixture.saveSeerr("https://seerr.lifecycle.test", for: first)
        try fixture.headers.setHeaders(token, forHost: "jf.lifecycle.test")
        try fixture.headers.setHeaders(token, forHost: "seerr.lifecycle.test")
        let store = fixture.store()

        // Another account on the same server still needs both.
        try store.remove(first)
        #expect(!fixture.headers.headers(forHost: "jf.lifecycle.test").isEmpty)
        #expect(!fixture.headers.headers(forHost: "seerr.lifecycle.test").isEmpty)

        try store.remove(second)
        #expect(fixture.headers.headers(forHost: "jf.lifecycle.test").isEmpty)
        #expect(fixture.headers.headers(forHost: "seerr.lifecycle.test").isEmpty)
    }

    @Test func forgettingASeerrKeepsHeadersAnotherServersSeerrStillUses() throws {
        let fixture = try Fixture(accounts: [first, other])
        fixture.saveSeerr("https://seerr.lifecycle.test", for: first)
        fixture.saveSeerr("https://seerr.lifecycle.test", for: other)
        try fixture.headers.setHeaders(token, forHost: "seerr.lifecycle.test")
        let store = fixture.store()

        fixture.defaults.removeObject(forKey: AccountLocalData.seerrServerKey(first))
        store.seerr.releaseServerHeaders("seerr.lifecycle.test")
        #expect(!fixture.headers.headers(forHost: "seerr.lifecycle.test").isEmpty)

        fixture.defaults.removeObject(forKey: AccountLocalData.seerrServerKey(other))
        store.seerr.releaseServerHeaders("seerr.lifecycle.test")
        #expect(fixture.headers.headers(forHost: "seerr.lifecycle.test").isEmpty)
    }

    @Test func cancellingAnAddedServerBeforeSignInTakesItsStagedHeaders() async throws {
        let fixture = try Fixture(accounts: [other])
        let draft = fixture.store(draft: true)
        try fixture.headers.stage(token, for: "https://jf.lifecycle.test", service: .jellyfin)
        try await draft.connect(to: "https://jf.lifecycle.test")
        #expect(draft.phase == .needsSignIn)

        draft.cancelAccountDraft()
        #expect(fixture.headers.headers(forHost: "jf.lifecycle.test").isEmpty)

        // A server that already has an account keeps them.
        try fixture.headers.setHeaders(token, forHost: "other.lifecycle.test")
        let again = fixture.store(draft: true)
        try await again.connect(to: "https://other.lifecycle.test")
        again.cancelAccountDraft()
        #expect(!fixture.headers.headers(forHost: "other.lifecycle.test").isEmpty)
    }

    @Test func changingServerBeforeTheFirstSignInTakesItsStagedHeaders() async throws {
        let fixture = try Fixture(accounts: [])
        let store = fixture.store()
        try fixture.headers.stage(token, for: "https://jf.lifecycle.test", service: .jellyfin)
        try await store.connect(to: "https://jf.lifecycle.test")

        await store.forgetServer()
        #expect(fixture.headers.headers(forHost: "jf.lifecycle.test").isEmpty)
    }
}

private nonisolated final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
