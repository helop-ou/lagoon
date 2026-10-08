import Foundation
import Testing
@testable import Lagoon

/// Library search as typed: the pause before a query runs, which query owns
/// the screen, and what a failure shows.
@Suite("Library search", .serialized)
@MainActor
struct SearchViewModelTests {
    private static let host = "search-model.test"

    private func makeClient() -> JellyfinClient {
        SearchFixture.reset()
        StubURLProtocol.register(host: Self.host, handler: SearchFixture.respond)
        return StubURLProtocol.makeJellyfinClient(host: Self.host, deviceId: "search-model-tests")
    }

    private var searchedTerms: [String] {
        StubURLProtocol.requests(host: Self.host).compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "SearchTerm" }?.value
        }
    }

    @Test func onlyTheQueryTypedLastRunsOnceTypingPauses() async throws {
        let client = makeClient()
        let pause = DebounceGate()
        let model = SearchViewModel(debounce: { await pause.wait() })

        model.search("d", client: client)
        model.search("du", client: client)
        model.search("dune", client: client)
        try await pause.waitForWaiters(3)
        #expect(searchedTerms.isEmpty)

        await pause.open()
        await model.searchTask?.value
        #expect(searchedTerms == ["dune"])
        #expect(model.results.map(\.id) == ["dune"])
        #expect(!model.isSearching)
    }

    @Test func aQueryStartedBeforeAnAccountSwitchNeverRuns() async throws {
        let client = makeClient()
        let pause = DebounceGate()
        let model = SearchViewModel(debounce: { await pause.wait() })

        model.search("dune", client: client)
        try await pause.waitForWaiters(1)
        client.activateSession(token: "other-token", userId: "other-user")
        await pause.open()
        await model.searchTask?.value

        #expect(searchedTerms.isEmpty)
        #expect(model.results.isEmpty)
    }

    @Test func resultsStayWhileTheSameQueryRunsAgainAndClearForANewOne() async throws {
        let client = makeClient()
        let model = SearchViewModel(debounce: {})
        model.search("dune", client: client)
        await model.searchTask?.value
        #expect(model.results.map(\.id) == ["dune"])

        // The same words with different padding are the same query.
        model.search(" dune ", client: client)
        #expect(model.results.map(\.id) == ["dune"])
        #expect(model.isSearching)
        await model.searchTask?.value

        model.search("arrival", client: client)
        #expect(model.results.isEmpty)
        await model.searchTask?.value
        #expect(model.results.map(\.id) == ["arrival"])
    }

    @Test func aFailedSearchSaysSoAndShowsNothing() async throws {
        let client = makeClient()
        let model = SearchViewModel(debounce: {})
        model.search("dune", client: client)
        await model.searchTask?.value
        SearchFixture.setFailing(true)

        model.search("arrival", client: client)
        await model.searchTask?.value

        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
        #expect(model.errorMessage == "Couldn't search your library.")

        SearchFixture.setFailing(false)
        model.search("arrival", client: client)
        #expect(model.errorMessage == nil)
    }
}

/// Holds every debounced query until the test opens it.
private actor DebounceGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// Returns once `count` queries are paused here.
    func waitForWaiters(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while waiters.count < count {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Answers each search with one movie named after the term.
private nonisolated enum SearchFixture {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var isFailing = false

    static func reset() { lock.withLock { isFailing = false } }
    static func setFailing(_ value: Bool) { lock.withLock { isFailing = value } }

    static func respond(to request: URLRequest) throws -> (Int, [String: String], Data) {
        if lock.withLock({ isFailing }) { return (500, [:], Data()) }
        let term = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "SearchTerm" }?.value ?? ""
        let body = "{\"Items\":[{\"Id\":\"\(term)\",\"Name\":\"\(term)\",\"Type\":\"Movie\"}],\"TotalRecordCount\":1}"
        return (200, ["Content-Type": "application/json"], Data(body.utf8))
    }
}
