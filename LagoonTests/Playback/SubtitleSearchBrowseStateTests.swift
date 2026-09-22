import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// The Subtitles tab is either choosing a track or browsing search
/// results. These pin the coordinator half of that — the panel can only be as
/// honest about which state it is in as the state it reads.
@Suite("Subtitle search browse state", .serialized)
struct SubtitleSearchBrowseStateTests {
    @Test @MainActor func searchingOpensTheResultsBrowser() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.detach() }
        #expect(!coordinator.isBrowsingResults)

        coordinator.startSearch()

        #expect(coordinator.isBrowsingResults)
        #expect(coordinator.phase == .searching)
        try await waitUntil { coordinator.phase == .idle }
        #expect(coordinator.results.count == 2)
        #expect(coordinator.isBrowsingResults)
    }

    @Test @MainActor func closingResultsReturnsToTheTrackList() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.detach() }
        coordinator.startSearch()
        try await waitUntil { !coordinator.results.isEmpty }

        coordinator.closeResults()

        #expect(!coordinator.isBrowsingResults)
        #expect(coordinator.results.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test @MainActor func closingResultsMidSearchAbandonsIt() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.detach() }
        coordinator.startSearch()
        #expect(coordinator.phase == .searching)

        coordinator.closeResults()

        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isBrowsingResults)
        // The abandoned search must not surface its answer after the viewer
        // has gone back to the track list.
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.phase == .idle)
        #expect(coordinator.results.isEmpty)
    }

    @Test @MainActor func closingResultsKeepsADownloadFailureOnScreen() async throws {
        let engine = SampleBufferPlayerEngine()
        let coordinator = makeCoordinator(engine: engine)
        defer { coordinator.detach(); engine.shutdown() }
        coordinator.startSearch()
        try await waitUntil { !coordinator.results.isEmpty }
        let broken = try #require(coordinator.results.first { $0.providerID == "broken" })
        coordinator.startDownload(broken)
        try await waitUntil {
            if case .downloadFailed = coordinator.phase { return true }
            return false
        }

        coordinator.closeResults()

        // The status line lives above the track list now, so it is the only
        // thing left that can explain what happened to the chosen result.
        guard case .downloadFailed = coordinator.phase else {
            Issue.record("Closing the browser must not erase a download failure")
            return
        }
        #expect(!coordinator.isBrowsingResults)
        #expect(coordinator.results.isEmpty)
    }

    @Test @MainActor func changingLanguageWhileBrowsingSearchesAgain() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.detach() }
        coordinator.startSearch()
        try await waitUntil { coordinator.phase == .idle }

        coordinator.selectLanguage("est")

        #expect(coordinator.phase == .searching)
        #expect(coordinator.isBrowsingResults)
        try await waitUntil { coordinator.phase != .searching }
        #expect(coordinator.results.count == 1)
        #expect(BrowseStateURLProtocol.requests.contains("/Items/item-1/RemoteSearch/Subtitles/est"))

        coordinator.cycleLanguage()
        #expect(coordinator.phase == .searching)
        try await waitUntil { coordinator.phase != .searching }
    }

    @Test @MainActor func changingLanguageOnTheTrackListDoesNotSearch() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.detach() }
        coordinator.startSearch()
        try await waitUntil { coordinator.phase == .idle }
        coordinator.closeResults()
        let requestsBefore = BrowseStateURLProtocol.requests.count

        coordinator.selectLanguage("est")

        #expect(coordinator.selectedLanguage == "est")
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isBrowsingResults)
        try await Task.sleep(for: .milliseconds(200))
        #expect(BrowseStateURLProtocol.requests.count == requestsBefore)
    }

    @Test @MainActor func afinishedDownloadReturnsToTheTrackList() async throws {
        let engine = SampleBufferPlayerEngine()
        let coordinator = makeCoordinator(engine: engine)
        defer { coordinator.detach(); engine.shutdown() }
        coordinator.startSearch()
        try await waitUntil { !coordinator.results.isEmpty }
        let good = try #require(coordinator.results.first { $0.providerID == "good" })

        coordinator.startDownload(good)
        try await waitUntil { coordinator.phase == .downloaded }

        // The chosen result is a track now; the viewer belongs back in the
        // list where it is selected, with the status line explaining it.
        #expect(!coordinator.isBrowsingResults)
        #expect(coordinator.results.isEmpty)
        #expect(engine.subtitleTracks.contains { $0.isSelected && $0.source == .downloaded })
    }

    @Test @MainActor func detachingLeavesTheBrowser() async throws {
        let coordinator = makeCoordinator()
        coordinator.startSearch()
        #expect(coordinator.isBrowsingResults)

        coordinator.detach()

        #expect(!coordinator.isBrowsingResults)
        #expect(coordinator.results.isEmpty)
    }

    // MARK: - Fixtures

    @MainActor
    private func makeCoordinator(
        engine: SampleBufferPlayerEngine? = nil
    ) -> SubtitleSearchCoordinator {
        BrowseStateURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowseStateURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "subtitle-browse-test",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://browse.test")!)
        client.activateSession(token: "test-token", userId: "user-1")

        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        coordinator.configure(
            client: client,
            engine: engine ?? SampleBufferPlayerEngine(),
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        return coordinator
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 300,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Condition never became true")
    }
}

/// Minimal Jellyfin stand-in for the browse-state flow: one language with two
/// results (one downloadable, one the provider refuses), one with a single
/// result, and the permission probe every remote call makes first.
private nonisolated final class BrowseStateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [String] = []

    static var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "browse.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.recorded.append(url.path)
        Self.lock.unlock()

        let payload: Data
        let status: Int
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/Users/Me"):
            payload = Data(#"{ "Id": "user-1", "Name": "Tester", "Policy": { "EnableSubtitleManagement": true } }"#.utf8)
            status = 200
        case ("GET", "/Items/item-1/RemoteSearch/Subtitles/eng"):
            payload = Data(#"""
            [{
              "Id": "good",
              "Name": "English provider subtitle",
              "ThreeLetterISOLanguageName": "eng",
              "ProviderName": "Test Provider",
              "Format": "srt"
            }, {
              "Id": "broken",
              "Name": "Refused provider subtitle",
              "ThreeLetterISOLanguageName": "eng",
              "ProviderName": "Test Provider",
              "Format": "srt"
            }]
            """#.utf8)
            status = 200
        case ("GET", "/Items/item-1/RemoteSearch/Subtitles/est"):
            payload = Data(#"""
            [{
              "Id": "eesti",
              "Name": "Eesti subtiitrid",
              "ThreeLetterISOLanguageName": "est",
              "ProviderName": "Test Provider",
              "Format": "srt"
            }]
            """#.utf8)
            status = 200
        case ("GET", "/Providers/Subtitles/Subtitles/good"):
            payload = Data(#"""
            1
            00:00:01,000 --> 00:00:03,000
            Downloaded subtitle cue
            """#.utf8)
            status = 200
        case ("GET", "/Providers/Subtitles/Subtitles/broken"):
            // A hard client error: fails immediately and never reaches
            // Jellyfin's save fallback, so the test does not wait on retries.
            payload = Data()
            status = 400
        case ("POST", "/Videos/item-1/Subtitles"):
            payload = Data()
            status = 204
        default:
            payload = Data()
            status = 404
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": url.path.hasPrefix("/Providers/Subtitles/Subtitles/") && status == 200
                    ? "application/x-subrip"
                    : "application/json",
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
