import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// The Subtitles tab is either choosing a track or browsing search results.
/// These pin the coordinator's side of that state.
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
        // An abandoned search must not surface its answer later.
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

        // The status line is the only place left to explain the failure.
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
        #expect(browseRequestPaths().contains("/Items/item-1/RemoteSearch/Subtitles/est"))

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
        let requestsBefore = browseRequestPaths().count

        coordinator.selectLanguage("est")

        #expect(coordinator.selectedLanguage == "est")
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isBrowsingResults)
        try await Task.sleep(for: .milliseconds(200))
        #expect(browseRequestPaths().count == requestsBefore)
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

        // The result is a track now, so return to the list where it is selected.
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

    private func browseRequestPaths() -> [String] {
        StubURLProtocol.requests(host: "browse.test").map { $0.url?.path ?? "" }
    }

    @MainActor
    private func makeCoordinator(
        engine: SampleBufferPlayerEngine? = nil
    ) -> SubtitleSearchCoordinator {
        StubURLProtocol.register(host: "browse.test", handler: browseStateResponse)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "browse.test", deviceId: "subtitle-browse-test", token: "test-token", userId: "user-1"
        )

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
        try await Polling.untilMainActor(
            timeout: .milliseconds(attempts * 20), pollInterval: .milliseconds(20), condition: condition
        )
        if !condition() {
            Issue.record("Condition never became true")
        }
    }
}

/// Fake Jellyfin: one language with a good and a refused result, one with a
/// single result, and the permission probe.
private func browseStateResponse(to request: URLRequest) throws -> (Int, [String: String], Data) {
    guard let url = request.url else { throw URLError(.badURL) }

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
        // A 400 skips Jellyfin's save fallback, so no retries to wait on.
        payload = Data()
        status = 400
    case ("POST", "/Videos/item-1/Subtitles"):
        payload = Data()
        status = 204
    default:
        payload = Data()
        status = 404
    }

    let headers = [
        "Content-Type": url.path.hasPrefix("/Providers/Subtitles/Subtitles/") && status == 200
            ? "application/x-subrip"
            : "application/json",
    ]
    return (status, headers, payload)
}
