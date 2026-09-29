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
