import Foundation
import Testing
@testable import Lagoon

@Suite("Account-specific session expiry", .serialized)
@MainActor
struct SessionExpiryTests {
    @Test(arguments: ["Users/Me", "Items/film/PlaybackInfo", "Sessions/Playing/Progress"])
    func authenticatedRejectionPreservesIdentityAndPreferences(path: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try await fixture.settledStore()
        #expect(store.phase == .signedIn)
        let sentBefore = SessionExpiryProtocol.requests.count
        // Only the request under test is rejected. A background request the
        // store sends meanwhile succeeds, so it cannot be what expired the
        // session.
        SessionExpiryProtocol.setReply(.http(401, ""), forPathSuffix: path)
        do {
            _ = try await store.client.getData(path)
            Issue.record("A revoked token must fail")
        } catch JellyfinError.sessionExpired {
        }
        let underTest = SessionExpiryProtocol.requests.dropFirst(sentBefore).compactMap(\.url?.path)
            .filter { $0 == "/jellyfin/\(path)" }
        #expect(underTest.count == 1)
        #expect(store.phase == .needsSignIn)
        #expect(store.reauthenticationAccount?.id == fixture.first.id)
        #expect(store.activeAccount == nil)
        #expect(store.client.accessToken == nil)
        #expect(store.accounts.map(\.id) == [fixture.first.id, fixture.second.id])
        #expect(KeychainStore.string(for: fixture.first.keychainAccount) == nil)
        #expect(KeychainStore.string(for: fixture.second.keychainAccount) == "second-token")
        #expect(fixture.defaults.string(forKey: "preference.\(fixture.first.id)") == "preserved")
    }

    @Test func expiredCredentialsCannotReturnOnRelaunchAndReauthenticationReplacesThem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.setReply(.http(401, ""))
        _ = try? await store.client.currentUser()
        // A stale credential restored by the OS: the rejection marker still
        // prevents activation.
        try KeychainStore.set("first-token", for: fixture.first.keychainAccount)
        let relaunched = fixture.store()
        #expect(relaunched.phase == .needsSignIn)
        #expect(relaunched.reauthenticationAccount?.id == fixture.first.id)
        #expect(relaunched.client.accessToken == nil)
        SessionExpiryProtocol.setReply(.http(200, fixture.authenticationJSON))
        try await relaunched.signIn(username: "First", password: "synthetic-password")
        #expect(relaunched.phase == .signedIn)
        #expect(relaunched.activeAccount?.id == fixture.first.id)
        #expect(relaunched.reauthenticationAccount == nil)
        #expect(relaunched.accounts.count == 2)
        #expect(KeychainStore.string(for: fixture.first.keychainAccount) == "replacement-token")
        #expect(KeychainStore.string(for: fixture.second.keychainAccount) == "second-token")
        let restored = fixture.store()
        #expect(restored.phase == .signedIn)
        #expect(restored.client.accessToken == "replacement-token")
    }

    @Test func rejectedLoginDoesNotInvalidateAnExistingSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try await fixture.settledStore()
        // Only the sign-in is refused; a background read with the live token
        // must not be what decides the outcome.
        SessionExpiryProtocol.setReply(.http(401, ""), forPathSuffix: "AuthenticateByName")
        do {
            try await store.signIn(username: "First", password: "wrong")
            Issue.record("Incorrect credentials must fail")
        } catch JellyfinError.unauthorized {
        }
        #expect(store.phase == .signedIn)
        #expect(store.client.accessToken == "first-token")
        // Activation also reads the profile with the live token;
        // the request under test is the sign-in itself.
        let signIn = try #require(SessionExpiryProtocol.requests.last { $0.url?.path.hasSuffix("AuthenticateByName") == true })
        #expect(signIn.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
    }

    @Test(arguments: [403, 404, 500, 503])
    func permissionAndServerFailuresKeepTheSession(status: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.setReply(.http(status, ""))
        _ = try? await store.client.currentUser()
        #expect(store.phase == .signedIn)
        #expect(store.client.accessToken == "first-token")
        #expect(KeychainStore.string(for: fixture.first.keychainAccount) == "first-token")
    }

    @Test(arguments: [URLError.Code.timedOut, .notConnectedToInternet, .cannotConnectToHost])
    func networkFailuresKeepTheSession(code: URLError.Code) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.setReply(.failure(code))
        _ = try? await store.client.currentUser()
        #expect(store.phase == .signedIn)
        #expect(store.client.accessToken == "first-token")
        #expect(fixture.store().phase == .signedIn)
    }

    @Test func aLate401CannotExpireTheNewlySelectedAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.hold(pathSuffix: "Items/late")
        let pending = Task { try await store.client.getData("Items/late") }
        try await waitForHeldRequest()
        store.switchTo(fixture.second)
        SessionExpiryProtocol.releaseHeld(status: 401)
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(store.phase == .signedIn)
        #expect(store.activeAccount?.id == fixture.second.id)
        #expect(store.client.accessToken == "second-token")
        #expect(KeychainStore.string(for: fixture.first.keychainAccount) == "first-token")
    }

    @Test func aLate401CannotExpireAReplacementTokenForTheSameAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        // Held by path: activation's own profile reads must not take its place.
        SessionExpiryProtocol.hold(pathSuffix: "Items/late")
        let pending = Task { try await store.client.getData("Items/late") }
        try await waitForHeldRequest()
        SessionExpiryProtocol.setReply(.http(200, fixture.authenticationJSON))
        try await store.signIn(username: "First", password: "synthetic-password")
        SessionExpiryProtocol.releaseHeld(status: 401)
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(store.phase == .signedIn)
        #expect(store.client.accessToken == "replacement-token")
        #expect(KeychainStore.string(for: fixture.first.keychainAccount) == "replacement-token")
    }

    @Test func explicitSignOutStillForgetsAnAlreadyRevokedAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.setReply(.http(401, ""))
        await store.signOut()
        #expect(store.accounts.map(\.id) == [fixture.second.id])
        #expect(store.phase == .choosingAccount)
        #expect(store.reauthenticationAccount == nil)
    }

    /// `beginReauthentication` clears `activeAccount`, so `forgetServer`
    /// must not rely on it.
    @Test func changingServerWhileReauthenticatingStillForgetsThatAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.setReply(.http(401, ""))
        _ = try? await store.client.getData("Users/Me")
        #expect(store.reauthenticationAccount?.id == fixture.first.id)
        #expect(store.activeAccount == nil)

        await store.forgetServer()

        #expect(store.accounts.map(\.id) == [fixture.second.id])
        #expect(store.reauthenticationAccount == nil)
        #expect(store.phase == .needsServer)
        // The account on the other server keeps its credential.
        #expect(KeychainStore.string(for: fixture.second.keychainAccount) == "second-token")
    }

    @Test func signingOutOfTheLastAccountAsksForAServerNotAPassword() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try store.remove(fixture.second)
        #expect(store.accounts.map(\.id) == [fixture.first.id])

        await store.signOut()

        #expect(store.accounts.isEmpty)
        #expect(store.phase == .needsServer)
    }

    @Test func aPendingLogoutCannotClearTheNextAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        SessionExpiryProtocol.hold(pathSuffix: "Sessions/Logout")
        let pending = Task { await store.signOut() }
        try await waitForHeldRequest()
        store.switchTo(fixture.second)
        SessionExpiryProtocol.releaseHeld(status: 204)
        await pending.value
        #expect(store.phase == .signedIn)
        #expect(store.activeAccount?.id == fixture.second.id)
        #expect(store.client.accessToken == "second-token")
    }

    private func waitForHeldRequest() async throws {
        try await Polling.until(timeout: .seconds(1), pollInterval: .milliseconds(5)) {
            SessionExpiryProtocol.hasHeldRequest
        }
        guard SessionExpiryProtocol.hasHeldRequest else {
            Issue.record("The test request never reached the transport")
            throw CancellationError()
        }
    }

    @Test(arguments: [false, true])
    func lateDownloadPermissionCannotReturnTheNextAccountsPolicy(transcoding: Bool) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionExpiryProtocol.self]
        let client = JellyfinClient(deviceId: "permission-test", sessionConfiguration: config)
        client.configure(serverURL: try #require(URL(string: "https://permission.invalid")))
        client.activateSession(token: "first-token", userId: "first")
        SessionExpiryProtocol.reset()
        SessionExpiryProtocol.setReply(.hold)
        defer { SessionExpiryProtocol.releaseHeld(status: 500) }
        let pending = Task {
            if transcoding { return await client.refreshVideoTranscodingPermission() }
            return await client.refreshContentDownloadingPermission()
        }
        try await waitForHeldRequest()
        let administrator = try JellyfinClient.decoder.decode(
            UserPolicy.self, from: Data(#"{"IsAdministrator":true}"#.utf8)
        )
        client.activateSession(token: "second-token", userId: "second", policy: administrator)
        SessionExpiryProtocol.releaseHeld(status: 500)
        #expect(await pending.value == nil)
        #expect(client.cachedContentDownloadingAllowed == true)
        #expect(client.cachedVideoTranscodingAllowed == true)
    }

    /// Subtitle, download and transcode permissions share one `Users/Me`
    /// fetch: three concurrent callers still answer from a single response.
    @Test func oneUsersMeRequestAnswersAllThreePermissionFlags() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionExpiryProtocol.self]
        let client = JellyfinClient(deviceId: "policy-test", sessionConfiguration: config)
        client.configure(serverURL: try #require(URL(string: "https://policy.invalid")))
        client.activateSession(token: "token", userId: "user")
        SessionExpiryProtocol.reset()
        SessionExpiryProtocol.setReply(.http(200, #"""
        {"Id":"user","Policy":{"EnableSubtitleManagement":false,"EnableContentDownloading":true,"EnableVideoPlaybackTranscoding":false}}
        """#))

        async let subtitlesAllowed = client.canManageSubtitles()
        async let downloadsAllowed = client.canDownloadContent()
        async let transcodingAllowed = client.canTranscodeForDownload()
        let results = await (subtitlesAllowed, downloadsAllowed, transcodingAllowed)

        #expect(results.0 == false)
        #expect(results.1 == true)
        #expect(results.2 == false)
        let policyRequests = SessionExpiryProtocol.requests.filter { $0.url?.path.hasSuffix("Users/Me") == true }
        #expect(policyRequests.count == 1)
    }

    private final class Fixture {
        let suite = "SessionExpiryTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let first: StoredAccount
        let second: StoredAccount

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            first = StoredAccount(serverURL: URL(string: "https://first.invalid/jellyfin")!,
                                  serverName: "First server", userId: UUID().uuidString, userName: "First")
            second = StoredAccount(serverURL: URL(string: "https://second.invalid/jellyfin")!,
                                   serverName: "Second server", userId: UUID().uuidString, userName: "Second")
            try KeychainStore.set("first-token", for: first.keychainAccount)
            try KeychainStore.set("second-token", for: second.keychainAccount)
            defaults.set(try JSONEncoder().encode([first, second]), forKey: "accounts")
            defaults.set(first.id, forKey: "session.activeAccountId")
            defaults.set("preserved", forKey: "preference.\(first.id)")
            SessionExpiryProtocol.reset()
        }

        var authenticationJSON: String {
            "{\"AccessToken\":\"replacement-token\",\"User\":{\"Id\":\"\(first.userId)\",\"Name\":\"First\"}}"
        }

        func store() -> SessionStore {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SessionExpiryProtocol.self]
            return SessionStore(defaults: defaults, sessionConfiguration: config)
        }

        /// A store whose activation reads have all been answered, so the
        /// next reply reaches only the request under test. Activation reads
        /// the profile, and on iOS the download permission, on its own.
        @MainActor
        func settledStore() async throws -> SessionStore {
            SessionExpiryProtocol.setReply(.http(200, """
            {"Id":"\(first.userId)","Name":"First renamed","Policy":{"EnableContentDownloading":false}}
            """))
            let store = store()
            try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
                Self.activationReadsAnswered(store)
            }
            try #require(Self.activationReadsAnswered(store), "The activation reads never completed")
            return store
        }

        @MainActor
        private static func activationReadsAnswered(_ store: SessionStore) -> Bool {
            #if os(iOS)
            guard store.client.cachedContentDownloadingAllowed == false else { return false }
            #endif
            return store.userName == "First renamed"
        }

        func cleanUp() {
            SessionExpiryProtocol.releaseHeld(status: 500)
            try? KeychainStore.delete(first.keychainAccount)
            try? KeychainStore.delete(second.keychainAccount)
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private nonisolated final class SessionExpiryProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case http(Int, String), failure(URLError.Code), hold }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: Reply = .http(200, "{}")
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var held: [SessionExpiryProtocol] = []
    nonisolated(unsafe) private static var heldPathSuffix: String?
    nonisolated(unsafe) private static var scopedReply: (pathSuffix: String, reply: Reply)?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var hasHeldRequest: Bool { lock.withLock { !held.isEmpty } }
    static func setReply(_ value: Reply) { lock.withLock { reply = value } }
    /// Answers only requests whose path ends this way with `value`; every
    /// other request gets an empty success.
    static func setReply(_ value: Reply, forPathSuffix suffix: String) {
        lock.withLock { scopedReply = (suffix, value); reply = .http(200, "{}") }
    }
    /// Holds only requests whose path ends this way, whatever the reply, so
    /// background requests a store sends on activation are never the one held.
    static func hold(pathSuffix: String) { lock.withLock { heldPathSuffix = pathSuffix } }
    static func reset() {
        lock.withLock { recorded = []; held = []; heldPathSuffix = nil; scopedReply = nil; reply = .http(200, "{}") }
    }

    static func releaseHeld(status: Int) {
        let pending = lock.withLock { let result = held; held = []; return result }
        for request in pending { request.respond(status: status, body: "") }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock {
            Self.recorded.append(request)
            if let suffix = Self.heldPathSuffix, request.url?.path.hasSuffix(suffix) == true {
                Self.held.append(self)
                return Reply.hold
            }
            if let scoped = Self.scopedReply, request.url?.path.hasSuffix(scoped.pathSuffix) == true {
                if case .hold = scoped.reply { Self.held.append(self) }
                return scoped.reply
            }
            if case .hold = Self.reply { Self.held.append(self) }
            return Self.reply
        }
        switch response {
        case .http(let status, let body): respond(status: status, body: body)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hold: break
        }
    }
    override func stopLoading() {}
    private func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
