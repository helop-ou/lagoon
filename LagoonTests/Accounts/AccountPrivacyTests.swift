import Foundation
import Testing
@testable import Lagoon

@Suite("Account privacy lifecycle", .serialized)
@MainActor
struct AccountPrivacyTests {
    @Test func pickerSwitchingScopesHistoryWithoutAViewLifecycleHook() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(try JSONEncoder().encode(["Unattributed old search"]), forKey: "search.recents")
        let store = fixture.store()
        #expect(store.recentSearches.terms.isEmpty)
        store.recentSearches.record("A private search")
        store.showAccountPicker()
        #expect(store.activeAccount == nil)
        #expect(store.client.accessToken == nil)
        #expect(store.seerr.client.sessionCookie == nil)
        #expect(store.recentSearches.terms.isEmpty)
        store.switchTo(fixture.b)
        // Switching stamps the profile for the picker's "last used" order.
        #expect(store.accounts.first { $0.id == fixture.b.id }?.lastUsedAt != nil)
        #expect(store.recentSearches.terms.isEmpty)
        store.recentSearches.record("B private search")
        store.showAccountPicker()
        store.switchTo(fixture.a)
        #expect(store.recentSearches.terms == ["A private search"])
        #expect(fixture.credentials.string(for: fixture.b.keychainAccount) == "token-b")
        #expect(fixture.defaults.data(forKey: "search.recents") == nil)
    }

    @Test func forgettingInactiveAccountRemovesEveryCookieAndPreferenceOnlyForThatIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.switchTo(fixture.b)
        for prefix in Fixture.preferencePrefixes {
            fixture.defaults.set("A", forKey: prefix + fixture.a.id)
            fixture.defaults.set("B", forKey: prefix + fixture.b.id)
        }
        try store.remove(fixture.a)
        #expect(store.activeAccount?.id == fixture.b.id)
        #expect(store.client.accessToken == "token-b")
        #expect(store.accounts.map(\.id) == [fixture.b.id])
        #expect(fixture.credentials.string(for: fixture.a.keychainAccount) == nil)
        #expect(try fixture.credentials.accountNames().filter { $0.hasPrefix("seerr.cookie:\(fixture.a.id)|") }.isEmpty)
        #expect(fixture.credentials.string(for: fixture.cookieB) == "cookie-b")
        #expect(fixture.credentials.string(for: "unrelated.device-wide.token") == "device-wide-token")
        for prefix in Fixture.preferencePrefixes {
            #expect(fixture.defaults.object(forKey: prefix + fixture.a.id) == nil)
            #expect(fixture.defaults.string(forKey: prefix + fixture.b.id) == "B")
        }
    }

    @Test func forgettingAnAccountForgetsItsLibrarySelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.switchTo(fixture.b)
        var selection = LibrarySelection()
        selection.favoritesOnly = true
        selection.save(accountID: fixture.a.id, defaults: fixture.defaults)
        selection.save(accountID: fixture.b.id, defaults: fixture.defaults)
        try store.remove(fixture.a)
        #expect(LibrarySelection.restore(accountID: fixture.a.id, defaults: fixture.defaults) == LibrarySelection())
        #expect(LibrarySelection.restore(accountID: fixture.b.id, defaults: fixture.defaults) == selection)
    }

    /// The regression reset must reach every per-account record too.
    @Test func regressionResetCoversEveryPerAccountKey() {
        for prefix in AccountLocalData.perAccountKeyPrefixes {
            #expect(RegressionStateReset.keyPrefixes.contains { prefix.hasPrefix($0) }, "\(prefix)")
        }
    }

    @Test func logoutDropsLocalAccessBeforeNetworkAndLateCompletionCannotAffectB() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.recentSearches.record("A private search")
        PrivacyProtocol.setMode(.hold)
        let pending = Task { await store.signOut() }
        try await PrivacyProtocol.waitUntilHeld()
        #expect(store.activeAccount == nil)
        #expect(store.client.accessToken == nil)
        #expect(store.recentSearches.terms.isEmpty)
        #expect(store.accounts.map(\.id) == [fixture.b.id])
        #expect(fixture.credentials.string(for: fixture.a.keychainAccount) == nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) == nil)
        store.switchTo(fixture.b)
        PrivacyProtocol.releaseHeld()
        await pending.value
        #expect(store.activeAccount?.id == fixture.b.id)
        #expect(store.client.accessToken == "token-b")
    }

    @Test func offlineLogoutStillForgetsTheAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        await store.signOut()
        #expect(store.phase == .choosingAccount)
        #expect(store.accounts.map(\.id) == [fixture.b.id])
        #expect(fixture.credentials.string(for: fixture.a.keychainAccount) == nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) == nil)
        #expect(store.cleanupErrorMessage == nil)
    }

    @Test func failedDeletionIsQuarantinedAcrossRelaunchAndCanBeRetried() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        fixture.credentials.failDeletion = true
        #expect(throws: (any Error).self) { try store.remove(fixture.a) }
        #expect(store.activeAccount == nil)
        #expect(store.accounts.map(\.id) == [fixture.b.id])
        #expect(store.cleanupErrorMessage != nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) != nil)
        let reopened = fixture.store()
        #expect(reopened.cleanupErrorMessage != nil)
        #expect(reopened.activeAccount?.id != fixture.a.id)
        let data = AccountLocalData(defaults: fixture.defaults, credentials: fixture.credentials)
        #expect(data.pendingAccountIDs.contains(fixture.a.id))
        #expect(throws: (any Error).self) { try data.finishRemoval(accountID: fixture.a.id) }
        fixture.credentials.failDeletion = false
        reopened.retryCredentialCleanup()
        #expect(reopened.cleanupErrorMessage == nil)
        #expect(data.pendingAccountIDs.isEmpty)
        #expect(fixture.credentials.string(for: fixture.cookieA) == nil)
        #expect(fixture.credentials.string(for: fixture.a.keychainAccount) == nil)
        #expect(fixture.credentials.string(for: fixture.b.keychainAccount) == "token-b")
    }

    @Test func failedCookieEnumerationDoesNotClaimCleanupSucceeded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        fixture.credentials.failEnumeration = true
        #expect(throws: (any Error).self) { try store.remove(fixture.a) }
        #expect(store.cleanupErrorMessage != nil)
        #expect(store.client.accessToken == nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) != nil)
        fixture.credentials.failEnumeration = false
        store.retryCredentialCleanup()
        #expect(store.cleanupErrorMessage == nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) == nil)
    }

    @Test func accountDraftCancellationPreservesActiveHistoryAndCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.recentSearches.record("Keep this")
        let draft = store.makeAccountDraft()
        draft.cancelAccountDraft()
        store.isAddingAccount = false
        #expect(store.activeAccount?.id == fixture.a.id)
        #expect(store.recentSearches.terms == ["Keep this"])
        #expect(fixture.credentials.string(for: fixture.cookieA) == "cookie-a")
        #expect(fixture.credentials.string(for: fixture.a.keychainAccount) == "token-a")
    }

    @Test func readdingThroughTheSignInFlowCannotRestoreForgottenHistoryOrCookies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        store.recentSearches.record("Forgotten search")
        store.switchTo(fixture.b)
        try store.remove(fixture.a)
        let draft = store.makeAccountDraft()
        draft.client.configure(serverURL: fixture.a.serverURL)
        PrivacyProtocol.setMode(.authenticated)
        try await draft.signIn(username: "Viewer A", password: "synthetic")
        try store.finishAddingAccount(from: draft)
        #expect(store.activeAccount?.id == fixture.a.id)
        #expect(store.client.accessToken == "replacement-token")
        #expect(store.recentSearches.terms.isEmpty)
        #expect(fixture.credentials.string(for: fixture.cookieA) == nil)
        #expect(fixture.credentials.string(for: fixture.cookieB) == "cookie-b")
    }

    @Test func failedSeerrCookieDeletionCannotRestoreOnRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let data = AccountLocalData(defaults: fixture.defaults, credentials: fixture.credentials)
        fixture.credentials.failDeletion = true
        #expect(throws: (any Error).self) { try data.removeSeerrCookie(fixture.cookieA) }
        let reopened = AccountLocalData(defaults: fixture.defaults, credentials: fixture.credentials)
        #expect(reopened.pendingCookieKeys.contains(fixture.cookieA))
        #expect(!reopened.pendingCookieKeys.contains(fixture.cookieB))
        try reopened.saveSeerrCookie("replacement-cookie", for: fixture.cookieA)
        #expect(!reopened.pendingCookieKeys.contains(fixture.cookieA))
        #expect(fixture.credentials.string(for: fixture.cookieA) == "replacement-cookie")
    }

    @Test func sessionSnapshotKeepsItsOriginalServerAndCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let captured = store.client.sessionSnapshot()
        store.switchTo(fixture.b)
        _ = try? await captured.resumeItems()
        // Switching also refreshes the new account's profile;
        // the request under test is the snapshot's own.
        let request = try #require(PrivacyProtocol.requests.last { $0.url?.path.hasSuffix("Users/Me") == false })
        #expect(request.url?.host == "a.privacy.test")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("token-a") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("token-b") == false)
    }

    @Test func systemKeychainEnumerationSupportsScopedRemoval() throws {
        let suite = "AccountPrivacyKeychain.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let account = "https://\(UUID().uuidString.lowercased()).privacy.test|synthetic-user"
        let token = "token:\(account)"
        let cookie = "seerr.cookie:\(account)|https://seerr.privacy.test"
        let unrelated = "seerr.cookie:\(account)-other|https://seerr.privacy.test"
        defer {
            for key in [token, cookie, unrelated] { try? KeychainStore.delete(key) }
            defaults.removePersistentDomain(forName: suite)
        }
        try KeychainStore.set("synthetic-token", for: token)
        try KeychainStore.set("synthetic-cookie", for: cookie)
        try KeychainStore.set("keep", for: unrelated)
        let names = try KeychainStore.accountNames()
        #expect(names.contains(token))
        #expect(names.contains(cookie))
        let data = AccountLocalData(defaults: defaults, credentials: SystemAccountCredentials())
        data.beginRemoval(accountID: account)
        try data.finishRemoval(accountID: account)
        #expect(KeychainStore.string(for: token) == nil)
        #expect(KeychainStore.string(for: cookie) == nil)
        #expect(KeychainStore.string(for: unrelated) == "keep")
        #expect(data.pendingAccountIDs.isEmpty)
    }

    private final class Fixture {
        let suite = "AccountPrivacyTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let credentials = MemoryAccountCredentials()
        let a = StoredAccount(serverURL: URL(string: "https://a.privacy.test")!, serverName: "A", userId: "same-user", userName: "Viewer A")
        let b = StoredAccount(serverURL: URL(string: "https://b.privacy.test")!, serverName: "B", userId: "same-user", userName: "Viewer B")
        var cookieA: String { AccountLocalData.seerrCookieKey(a, serverURL: URL(string: "https://seerr-a.privacy.test")!) }
        var cookieB: String { AccountLocalData.seerrCookieKey(b, serverURL: URL(string: "https://seerr-b.privacy.test")!) }
        static let preferencePrefixes = AccountLocalData.perAccountKeyPrefixes
        init() throws {
            PrivacyProtocol.reset()
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(try JSONEncoder().encode([a, b]), forKey: "accounts")
            defaults.set(a.id, forKey: "session.activeAccountId")
            try credentials.set("token-a", for: a.keychainAccount)
            try credentials.set("token-b", for: b.keychainAccount)
            try credentials.set("cookie-a", for: cookieA)
            try credentials.set("old-cookie-a", for: AccountLocalData.seerrCookieKey(a, serverURL: URL(string: "https://old-seerr.privacy.test")!))
            try credentials.set("cookie-b", for: cookieB)
            try credentials.set("device-wide-token", for: "unrelated.device-wide.token")
        }
        func store() -> SessionStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PrivacyProtocol.self]
            return SessionStore(defaults: defaults, sessionConfiguration: configuration, credentials: credentials,
                                seerrClient: SeerrClient(session: URLSession(configuration: configuration)))
        }
        func cleanUp() { defaults.removePersistentDomain(forName: suite); PrivacyProtocol.releaseHeld() }
    }
}

nonisolated final class MemoryAccountCredentials: AccountCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failDeletion = false
    var failEnumeration = false
    func string(for account: String) -> String? { lock.withLock { values[account] } }
    func set(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    func delete(_ account: String) throws {
        if failDeletion { throw KeychainStore.StoreError.operationFailed("delete", -25308) }
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
    func accountNames() throws -> [String] {
        if failEnumeration { throw KeychainStore.StoreError.operationFailed("inspect", -25308) }
        return lock.withLock { Array(values.keys) }
    }
}

private nonisolated final class PrivacyProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case offline, hold, authenticated }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var mode: Mode = .offline
    private nonisolated(unsafe) static var recorded: [URLRequest] = []
    private nonisolated(unsafe) static var held: [PrivacyProtocol] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func setMode(_ value: Mode) { lock.withLock { mode = value } }
    static func reset() { lock.withLock { recorded = []; mode = .offline } }
    static func waitUntilHeld() async throws {
        for _ in 0..<200 {
            if lock.withLock({ !held.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    static func releaseHeld() {
        let pending = lock.withLock { let result = held; held = []; return result }
        for item in pending { item.client?.urlProtocol(item, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let shouldHold = Self.lock.withLock {
            Self.recorded.append(request)
            if Self.mode == .hold { Self.held.append(self); return true }
            return false
        }
        if Self.lock.withLock({ Self.mode == .authenticated }), let url = request.url {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"AccessToken":"replacement-token","User":{"Id":"same-user","Name":"Viewer A"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if !shouldHold { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override func stopLoading() {}
}
