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

/// Headers live in scopes on a host: host-wide while connecting, then the
/// server that answered.
@Suite("Server proxy header scopes")
struct ServerHeaderScopeTests {
    private let jf = [CustomHTTPHeader(name: "X-Token", value: "jf")]
    private let seerr = [CustomHTTPHeader(name: "X-Token", value: "seerr")]

    private func fields(_ store: ServerHeaderStore, _ address: String) -> [String: String] {
        store.fields(for: URL(string: address)!)
    }

    @Test func eachRequestGetsTheMostSpecificScopeCoveringIt() throws {
        let store = ServerHeaderStore(credentials: MemoryAccountCredentials())
        try store.setHeaders(jf, forServer: URL(string: "https://media.example.com/Jellyfin/")!)
        try store.setHeaders(seerr, forServer: URL(string: "https://media.example.com:5055")!)

        #expect(fields(store, "https://media.example.com/jellyfin/Items?x=1") == ["X-Token": "jf"])
        #expect(fields(store, "wss://media.example.com/jellyfin/socket") == ["X-Token": "jf"])
        #expect(fields(store, "https://media.example.com:5055/api/v1/status") == ["X-Token": "seerr"])
        // Neither covers these: another path, a path that only starts alike,
        // another port.
        #expect(fields(store, "https://media.example.com/other") == [:])
        #expect(fields(store, "https://media.example.com/jellyfinx/Items") == [:])
        #expect(fields(store, "https://media.example.com:50555/api") == [:])
        // A redirect off the host strips every scope's names.
        #expect(Set(store.headers(forHost: "media.example.com").map(\.value)) == ["jf", "seerr"])
    }

    @Test func stagingIsHostWideUntilAServerAnswers() throws {
        let store = ServerHeaderStore(credentials: MemoryAccountCredentials())
        try store.setHeaders(jf, forServer: URL(string: "https://media.example.com/jellyfin")!)

        try store.stage(seerr, for: "media.example.com/seerr", service: .seerr)
        // While Seerr connects, Jellyfin keeps its own.
        #expect(fields(store, "https://media.example.com/jellyfin/Items") == ["X-Token": "jf"])
        #expect(fields(store, "https://media.example.com/seerr/api/v1/status") == ["X-Token": "seerr"])

        store.narrow(toServer: URL(string: "https://media.example.com/seerr")!)
        #expect(fields(store, "https://media.example.com/seerr/api/v1/status") == ["X-Token": "seerr"])
        #expect(fields(store, "https://media.example.com/other") == [:])
        #expect(fields(store, "https://media.example.com/jellyfin/Items") == ["X-Token": "jf"])
    }

    @Test func aServerReachedOverPlainHTTPDropsWhatWasStaged() throws {
        let store = ServerHeaderStore(credentials: MemoryAccountCredentials())
        try store.stage(jf, for: "192.168.1.5", service: .jellyfin)
        store.narrow(toServer: URL(string: "http://192.168.1.5:8096")!)
        #expect(store.headers(forHost: "192.168.1.5").isEmpty)
    }

    @Test func headersStoredBeforeScopesCoverTheWholeHost() throws {
        let credentials = MemoryAccountCredentials()
        let legacy = try JSONEncoder().encode(jf)
        try credentials.set(String(decoding: legacy, as: UTF8.self), for: ServerHeaderStore.keychainAccount(forHost: "media.example.com"))
        let store = ServerHeaderStore(credentials: credentials)
        #expect(fields(store, "https://media.example.com/anything") == ["X-Token": "jf"])
    }

    @Test func anHTTPAddressUpgradedOnItsHostIsKeptAsHTTPS() {
        func base(_ requested: String, _ final: String?) -> String {
            ServerProbe.baseURL(URL(string: requested)!, answeredBy: final.flatMap(URL.init(string:))).absoluteString
        }
        #expect(base("http://media.example.com", "https://media.example.com/System/Info/Public") == "https://media.example.com")
        #expect(base("http://media.example.com/jellyfin", "https://media.example.com/jellyfin/System/Info/Public")
            == "https://media.example.com/jellyfin")
        // Not an upgrade on the same host: kept as typed.
        #expect(base("http://media.example.com", "https://login.example.net/System/Info/Public") == "http://media.example.com")
        #expect(base("http://media.example.com", "http://media.example.com/System/Info/Public") == "http://media.example.com")
        #expect(base("http://media.example.com", "https://media.example.com/login") == "http://media.example.com")
        #expect(base("https://media.example.com", "https://media.example.com/System/Info/Public") == "https://media.example.com")
        #expect(base("http://media.example.com", nil) == "http://media.example.com")
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
                stores: .isolated(defaults: defaults),
                publicInfo: { ServerProbe(info: PublicSystemInfo(serverName: "Fixture", version: "10.11.0", id: "fixture"), baseURL: $0) }
            )
        }

        func saveSeerr(_ address: String, for account: StoredAccount) {
            defaults.set(address, forKey: AccountLocalData.seerrServerKey(account))
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func serversInUseAreEveryAccountsServerAndItsSeerr() throws {
        let fixture = try Fixture(accounts: [first, other])
        fixture.saveSeerr("https://Seerr.Lifecycle.test:5055", for: first)
        #expect(SessionStore.serversInUse(accounts: [first, other], defaults: fixture.defaults).map(\.absoluteString)
            == ["https://jf.lifecycle.test", "https://Seerr.Lifecycle.test:5055", "https://other.lifecycle.test"])
    }

    @Test func aJellyfinAndASeerrOnOneHostKeepTheirOwnHeaders() throws {
        let jellyfin = StoredAccount(serverURL: URL(string: "https://media.lifecycle.test/jellyfin")!, serverName: "JF",
                                     userId: "one", userName: "One")
        let fixture = try Fixture(accounts: [jellyfin])
        fixture.saveSeerr("https://media.lifecycle.test/seerr", for: jellyfin)
        try fixture.headers.setHeaders([CustomHTTPHeader(name: "X-Token", value: "jf")], forServer: jellyfin.serverURL)
        try fixture.headers.setHeaders([CustomHTTPHeader(name: "X-Token", value: "seerr")],
                                       forServer: URL(string: "https://media.lifecycle.test/seerr")!)
        let store = fixture.store()

        fixture.defaults.removeObject(forKey: AccountLocalData.seerrServerKey(jellyfin))
        store.seerr.releaseServerHeaders(URL(string: "https://media.lifecycle.test/seerr"))
        #expect(fixture.headers.fields(for: URL(string: "https://media.lifecycle.test/seerr/api/v1/status")) == [:])
        #expect(fixture.headers.fields(for: URL(string: "https://media.lifecycle.test/jellyfin/Items")) == ["X-Token": "jf"])
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
        store.seerr.releaseServerHeaders(URL(string: "https://seerr.lifecycle.test"))
        #expect(!fixture.headers.headers(forHost: "seerr.lifecycle.test").isEmpty)

        fixture.defaults.removeObject(forKey: AccountLocalData.seerrServerKey(other))
        store.seerr.releaseServerHeaders(URL(string: "https://seerr.lifecycle.test"))
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

    @Test func anAddressUpgradedToHTTPSIsKeptAsHTTPSWithItsHeaders() async throws {
        let suite = "ServerHeaderLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let headers = ServerHeaderStore(credentials: MemoryAccountCredentials())
        let store = SessionStore(
            accountDraft: true, defaults: defaults, credentials: MemoryAccountCredentials(), serverHeaders: headers,
            publicInfo: { url in
                ServerProbe(
                    info: PublicSystemInfo(serverName: "Fixture", version: "10.11.0", id: "fixture"),
                    baseURL: ServerProbe.baseURL(url, answeredBy: URL(string: "https://jf.lifecycle.test/System/Info/Public"))
                )
            }
        )
        try headers.stage(token, for: "http://jf.lifecycle.test", service: .jellyfin)
        try await store.connect(to: "http://jf.lifecycle.test")
        #expect(store.client.serverURL?.absoluteString == "https://jf.lifecycle.test")
        // What playback's authorization is built from.
        #expect(headers.fields(for: store.client.serverURL) == ["CF-Access-Client-Secret": "secret"])
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
