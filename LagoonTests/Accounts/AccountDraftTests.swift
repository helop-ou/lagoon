import Foundation
import Testing
@testable import Lagoon

@Suite("Cancellable account setup")
@MainActor
struct AccountDraftTests {
    @Test func addingAndCancellingLeaveTheActiveSessionIntact() throws {
        let suite = "AccountDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let account = StoredAccount(serverURL: URL(string: "https://example.invalid/jellyfin")!,
                                    serverName: "Original", userId: UUID().uuidString, userName: "Viewer")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? KeychainStore.delete(account.keychainAccount)
        }
        try KeychainStore.set("test-token", for: account.keychainAccount)
        defaults.set(try JSONEncoder().encode([account]), forKey: "accounts")
        defaults.set(account.id, forKey: "session.activeAccountId")
        let session = SessionStore(defaults: defaults, sessionConfiguration: OfflineProtocol.configuration())
        let before = defaults.dictionaryRepresentation() as NSDictionary
        session.addAccount()
        let draft = session.makeAccountDraft()

        #expect(session.isAddingAccount)
        #expect(session.phase == .signedIn)
        #expect(session.activeAccount?.id == account.id)
        #expect(session.client.serverURL == account.serverURL)
        #expect(draft.phase == .needsSignIn)
        #expect(draft.client !== session.client)
        #expect(draft.client.serverURL == account.serverURL)
        #expect(draft.serverName == account.serverName)
        #expect(draft.client.accessToken == nil)
        #expect(draft.client.userId == nil)
        #expect(draft.userName == nil)
        #expect(draft.activeAccount == nil)
        #expect(draft.accounts.isEmpty)
        #expect(throws: CancellationError.self) { try session.finishAddingAccount(from: draft) }
        draft.cancelAccountDraft()
        session.isAddingAccount = false

        #expect(session.phase == .signedIn)
        #expect(session.activeAccount?.id == account.id)
        #expect(session.client.serverURL == account.serverURL)
        #expect(defaults.dictionaryRepresentation() as NSDictionary == before)
        #expect(KeychainStore.string(for: account.keychainAccount) == "test-token")
        #expect(throws: CancellationError.self) { try session.finishAddingAccount(from: draft) }
    }

    @Test func cancelledDraftCannotStartNetworkAuthentication() async {
        let draft = SessionStore(accountDraft: true, sessionConfiguration: OfflineProtocol.configuration())
        draft.cancelAccountDraft()
        await #expect(throws: CancellationError.self) {
            try await draft.connect(to: "https://example.invalid")
        }
        await #expect(throws: CancellationError.self) {
            try await draft.signIn(username: "test", password: "test")
        }
        await #expect(throws: CancellationError.self) {
            _ = try await draft.pollQuickConnect(secret: "test")
        }
        #expect(draft.phase == .needsServer)
    }

    @Test func changingDraftServerDoesNotForgetTheExistingAccount() async throws {
        let suite = "AccountDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let account = StoredAccount(serverURL: URL(string: "https://original.invalid")!,
                                    serverName: "Original", userId: UUID().uuidString, userName: "Viewer")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? KeychainStore.delete(account.keychainAccount)
        }
        try KeychainStore.set("test-token", for: account.keychainAccount)
        defaults.set(try JSONEncoder().encode([account]), forKey: "accounts")
        defaults.set(account.id, forKey: "session.activeAccountId")
        defaults.set(account.serverURL.absoluteString, forKey: "server.url")
        let session = SessionStore(defaults: defaults, sessionConfiguration: OfflineProtocol.configuration())
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let draft = session.makeAccountDraft()
        #expect(draft.phase == .needsSignIn)

        await draft.forgetServer()
        #expect(draft.phase == .needsServer)
        #expect(draft.serverName == nil)
        #expect(draft.activeAccount == nil)
        #expect(draft.client.accessToken == nil)
        #expect(session.phase == .signedIn)
        #expect(session.activeAccount?.id == account.id)
        #expect(session.client.serverURL == account.serverURL)
        #expect(session.client.accessToken == "test-token")
        #expect(KeychainStore.string(for: account.keychainAccount) == "test-token")
        #expect(defaults.dictionaryRepresentation() as NSDictionary == before)

        draft.cancelAccountDraft()
        let reopened = session.makeAccountDraft()
        #expect(reopened !== draft)
        #expect(reopened.phase == .needsSignIn)
        #expect(reopened.client.serverURL == account.serverURL)
        #expect(reopened.client.accessToken == nil)
    }

    @Test(arguments: [false, true])
    func noActiveAccountStartsAtServerEntry(hasRememberedAccount: Bool) throws {
        let suite = "AccountDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if hasRememberedAccount {
            let account = StoredAccount(serverURL: URL(string: "https://example.invalid")!,
                                        serverName: "Remembered", userId: UUID().uuidString, userName: "Viewer")
            defaults.set(try JSONEncoder().encode([account]), forKey: "accounts")
        }
        let session = SessionStore(defaults: defaults, sessionConfiguration: OfflineProtocol.configuration())
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let draft = session.makeAccountDraft()

        #expect(session.activeAccount == nil)
        #expect(draft.phase == .needsServer)
        #expect(draft.serverName == nil)
        #expect(draft.client.serverURL == nil)
        #expect(draft.client.accessToken == nil)
        #expect(defaults.dictionaryRepresentation() as NSDictionary == before)
    }

    @Test func draftUsesTheActiveServerNotTheFirstRememberedServer() throws {
        let suite = "AccountDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = StoredAccount(serverURL: URL(string: "https://first.invalid")!,
                                  serverName: "First", userId: UUID().uuidString, userName: "Viewer")
        let active = StoredAccount(serverURL: URL(string: "https://active.invalid/jellyfin")!,
                                   serverName: "Active", userId: UUID().uuidString, userName: "Viewer")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? KeychainStore.delete(active.keychainAccount)
        }
        try KeychainStore.set("test-token", for: active.keychainAccount)
        defaults.set(try JSONEncoder().encode([first, active]), forKey: "accounts")
        defaults.set(active.id, forKey: "session.activeAccountId")
        let session = SessionStore(defaults: defaults, sessionConfiguration: OfflineProtocol.configuration())
        let draft = session.makeAccountDraft()

        #expect(draft.phase == .needsSignIn)
        #expect(draft.client.serverURL == active.serverURL)
        #expect(draft.serverName == active.serverName)
        #expect(draft.client.accessToken == nil)
        #expect(draft.client.userId == nil)
    }
}

/// Fails every request without leaving the process; activation's profile
/// read would otherwise reach the real network.
private nonisolated final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
