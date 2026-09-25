import Foundation
import Testing
@testable import Lagoon

@Suite("Adaptive artwork sizing")
struct ArtworkSizingTests {
    @Test func usesPhysicalPixelsAndRoundsUp() {
        #expect(ArtworkSizing.pixels(for: 158, displayScale: 3) == 474)
        #expect(ArtworkSizing.pixels(for: 105.3, displayScale: 3) == 316)
        #expect(ArtworkSizing.pixels(for: 280, displayScale: 2) == 560)
    }

    @Test func boundsInvalidOrExcessiveRequests() {
        #expect(ArtworkSizing.pixels(for: .infinity, displayScale: 3) == 1)
        #expect(ArtworkSizing.pixels(for: -10, displayScale: 3) == 1)
        #expect(ArtworkSizing.pixels(for: 9000, displayScale: 3) == 3840)
        #expect(ArtworkSizing.pixels(for: 100, displayScale: 0) == 100)
    }
}

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
        let session = SessionStore(defaults: defaults)
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
        let draft = SessionStore(accountDraft: true)
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
        let session = SessionStore(defaults: defaults)
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
        let session = SessionStore(defaults: defaults)
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
        let session = SessionStore(defaults: defaults)
        let draft = session.makeAccountDraft()

        #expect(draft.phase == .needsSignIn)
        #expect(draft.client.serverURL == active.serverURL)
        #expect(draft.serverName == active.serverName)
        #expect(draft.client.accessToken == nil)
        #expect(draft.client.userId == nil)
    }
}

@Suite("Search pagination")
@MainActor
struct SearchPaginationTests {
    private func item(_ id: String) throws -> SearchResultItem {
        .library(try JellyfinClient.decoder.decode(MediaItem.self,
            from: Data("{\"Id\":\"\(id)\",\"Type\":\"Movie\"}".utf8)))
    }

    @Test func rawLibraryOffsetsSurviveFiltering() throws {
        let response = try JellyfinClient.decoder.decode(ItemsPage.self, from: Data(#"{"Items":[{"Id":"empty","Type":"BoxSet","ChildCount":0},{"Id":"movie","Type":"Movie"}],"TotalRecordCount":3}"#.utf8))
        let page = SearchResultsPage.library(response, offset: 0, limit: 2)
        #expect(page.items.map(\.id) == ["library:movie"])
        #expect(page.nextOffset == 2)
        #expect(SearchResultsPage.library(response, offset: 2, limit: 2).nextOffset == nil)
    }

    @Test func filteredSeerrPagesStillOfferTheNextPage() throws {
        let response = try JSONDecoder().decode(SeerrDiscoverPage.self, from: Data(#"{"page":1,"totalPages":2,"totalResults":21,"results":[{"id":1,"mediaType":"person","name":"Person"}]}"#.utf8))
        let page = SearchResultsPage.seerr(response)
        #expect(page.items.isEmpty)
        #expect(page.nextOffset == 1)
    }

    @Test func movieAndShowWithTheSameTMDBNumberAreDistinct() throws {
        let response = try JSONDecoder().decode(SeerrDiscoverPage.self, from: Data(#"{"page":1,"totalPages":1,"totalResults":2,"results":[{"id":1,"mediaType":"movie","title":"Movie"},{"id":1,"mediaType":"tv","name":"Show"}]}"#.utf8))
        let page = SearchResultsPage.seerr(response)
        #expect(Set(page.items.map(\.id)).count == 2)
        #expect(page.nextOffset == nil)
    }

    @Test func deduplicatesPagesAndStopsAtTheEnd() async throws {
        let model = SearchResultsViewModel()
        let first = try item("a"), second = try item("b")
        await model.loadNext { offset in
            #expect(offset == 0)
            return SearchResultsPage(items: [first, first], nextOffset: 2)
        }
        await model.loadNext { offset in
            #expect(offset == 2)
            return SearchResultsPage(items: [first, second], nextOffset: nil)
        }
        await model.loadNext { _ in
            Issue.record("Requested another page after the end")
            return SearchResultsPage(items: [], nextOffset: nil)
        }
        #expect(model.items.map(\.id) == ["library:a", "library:b"])
        #expect(!model.isLoading)
    }

    @Test func failuresPreserveTheCursorAndLoadedResultsForRetry() async throws {
        let model = SearchResultsViewModel()
        let first = try item("a")
        await model.loadNext { _ in SearchResultsPage(items: [first], nextOffset: 1) }
        await model.loadNext { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.items.count == 1)
        #expect(model.nextOffset == 1)
        #expect(model.errorMessage != nil)
        await model.loadNext { offset in
            #expect(offset == 1)
            return SearchResultsPage(items: [], nextOffset: nil)
        }
        #expect(model.errorMessage == nil)
    }

    /// A spent cursor makes `loadNext` a no-op, so retry must rewind it.
    @Test func retryingAnEmptyPageRewindsTheCursorAndSearchesAgain() async throws {
        let model = SearchResultsViewModel()
        await model.loadNext { _ in SearchResultsPage(items: [], nextOffset: nil) }
        #expect(model.items.isEmpty)
        #expect(model.nextOffset == nil)

        model.restart()
        #expect(model.nextOffset == 0)
        let found = try item("a")
        await model.loadNext { offset in
            #expect(offset == 0)
            return SearchResultsPage(items: [found], nextOffset: nil)
        }
        #expect(model.items.map(\.id) == ["library:a"])
    }

    @Test func cancellationDoesNotApplyLateResults() async throws {
        let model = SearchResultsViewModel()
        let first = try item("a")
        let task = Task {
            await model.loadNext { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return SearchResultsPage(items: [first], nextOffset: 1)
            }
        }
        await task.value
        #expect(model.items.isEmpty)
        #expect(model.nextOffset == 0)
        #expect(!model.isLoading)
    }
}
