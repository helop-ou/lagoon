import Foundation
import Testing
@testable import Lagoon

@Suite("First run", .serialized)
@MainActor
struct FirstRunTests {
    @Test func aFreshInstallWelcomesBeforeAskingForAServer() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        #expect(store.phase == .welcome)
        store.finishWelcome()
        #expect(store.phase == .needsServer)
    }

    @Test func anInterruptedSignInSkipsTheWelcome() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Fixture.server.absoluteString, forKey: "server.url")
        #expect(fixture.store().phase == .needsSignIn)
    }

    @Test func changingServerNeverWelcomesAgain() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.finishWelcome()
        try await store.connect(to: Fixture.server.absoluteString)
        #expect(store.phase == .needsSignIn)
        await store.forgetServer()
        #expect(store.phase == .needsServer)
    }

    @Test func theFirstSignInOffersSeerrBeforeHome() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try await fixture.signIn(store)
        #expect(store.phase == .offeringSeerr)
        #expect(store.activeAccount?.userId == "viewer")
        store.finishSeerrOffer()
        #expect(store.phase == .signedIn)
    }

    @Test func aServerThatAlreadyHasSeerrGoesStraightHome() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("https://seerr.first-run.test", forKey: "seerr.server.\(Fixture.server.absoluteString)")
        let store = fixture.store()
        try await fixture.signIn(store)
        #expect(store.phase == .signedIn)
    }

    @Test func anInstallWithAnotherAccountGoesStraightHome() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let other = StoredAccount(serverURL: URL(string: "https://other.first-run.test")!, serverName: "Other",
                                  userId: "other", userName: "Other viewer")
        fixture.defaults.set(try JSONEncoder().encode([other]), forKey: "accounts")
        let store = fixture.store()
        #expect(store.phase == .choosingAccount)
        try await fixture.signIn(store)
        #expect(store.phase == .signedIn)
    }

    @Test func addingAnAccountNeverOffersSeerr() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let draft = fixture.store().makeAccountDraft()
        try await fixture.signIn(draft)
        #expect(draft.phase == .signedIn)
    }

    @Test func finishingAStepOutOfTurnChangesNothing() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.finishSeerrOffer()
        #expect(store.phase == .welcome)
        store.finishWelcome()
        store.finishWelcome()
        store.finishSeerrOffer()
        #expect(store.phase == .needsServer)
    }
}

private struct Fixture {
    static let server = URL(string: "https://first-run.test")!
    let suite = "FirstRunTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let credentials = MemoryAccountCredentials()

    init() {
        defaults = UserDefaults(suiteName: suite)!
        StubURLProtocol.register(host: Self.server.host()!) { request in
            guard request.url?.path.hasSuffix("AuthenticateByName") == true else { return (404, [:], Data()) }
            return (200, [:], Data(#"{"AccessToken":"token","User":{"Id":"viewer","Name":"Viewer"}}"#.utf8))
        }
    }

    @MainActor
    func store() -> SessionStore {
        let session = URLSession(configuration: StubURLProtocol.configuration())
        return SessionStore(
            defaults: defaults, sessionConfiguration: StubURLProtocol.configuration(), credentials: credentials,
            seerrClient: SeerrClient(session: session), stores: .isolated(defaults: defaults),
            publicInfo: { ServerProbe(info: PublicSystemInfo(serverName: "First run", version: "10.11.0", id: "fixture"), baseURL: $0) }
        )
    }

    @MainActor
    func signIn(_ store: SessionStore) async throws {
        store.finishWelcome()
        try await store.connect(to: Self.server.absoluteString)
        try await store.signIn(username: "Viewer", password: "")
    }

    func cleanUp() {
        StubURLProtocol.unregister(host: Self.server.host()!)
        defaults.removePersistentDomain(forName: suite)
    }
}
