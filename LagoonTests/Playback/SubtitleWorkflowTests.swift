import Foundation
import Testing
@testable import LagoonEngine
@testable import Lagoon

@Suite("Subtitle workflow", .serialized)
struct SubtitleWorkflowTests {
    @Test func appleLanguagesAreOrderedDeduplicatedAndConvertedForJellyfin() {
        #expect(SubtitlePreferencesStore.deduplicated([
            "et-EE", "en-US", "et", "EN_GB",
        ]) == ["et", "en"])
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "et-EE") == "est")
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "en") == "eng")
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "ar") == "ara")
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "cs-CZ") == "ces")
    }

    @Test func remoteSubtitleMetadataDecodesWithoutProviderSpecificLogic() throws {
        let json = Data(#"""
        {
          "Id": "eng-provider-42",
          "Name": "Release.Name",
          "ThreeLetterISOLanguageName": "eng",
          "ProviderName": "Open Subtitles",
          "Format": "srt",
          "CommunityRating": 8.7,
          "DownloadCount": 1234,
          "IsHashMatch": true,
          "HearingImpaired": true,
          "MachineTranslated": false,
          "AiTranslated": false,
          "FrameRate": 23.976
        }
        """#.utf8)
        let result = try JellyfinClient.decoder.decode(RemoteSubtitleInfo.self, from: json)
        #expect(result.id == "eng-provider-42")
        #expect(result.threeLetterISOLanguageName == "eng")
        #expect(result.providerName == "Open Subtitles")
        #expect(result.hearingImpaired == true)
        #expect(result.isHashMatch == true)
    }

    @Test @MainActor func inPlayerLanguageChoicesStayCompactAndPreferenceOrdered() {
        let choices = SubtitleSearchCoordinator.makeLanguageChoices(
            preferredLanguages: ["is-IS", "en-US", "is"]
        )
        #expect(choices.prefix(2) == ["is", "en"])
        #expect(Set(choices).count == choices.count)
        #expect(choices.count <= SubtitlePreferencesStore.commonLanguageChoices.count + 2)
        #expect(choices.count < SubtitlePreferencesStore.allLanguageChoices.count)
    }

    @Test func subtitleFailuresKeepTheCauseTheViewerCanActOn() {
        // A 403 is a server permission, not an exhausted quota.
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 403)) == .notPermitted)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 401)) == .sessionExpired)
        #expect(SubtitleDownloadError.classify(JellyfinError.unauthorized) == .sessionExpired)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 429)) == .rateLimited)
        // No body: use our own wording.
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 502)) == .providerUnavailable)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 404)) == .server(404))
        #expect(SubtitleDownloadError.classify(URLError(.timedOut)) == .timedOut)
        #expect(SubtitleDownloadError.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(SubtitleDownloadError.classify(SubtitleDownloadError.unsupportedFile) == .unsupportedFile)

        let permission = SubtitleDownloadError.notPermitted.errorDescription ?? ""
        // The message names the dashboard switch the administrator flips.
        #expect(permission.contains("Allow subtitle management"))
        // The quota wording must not appear on failures that are not quota.
        #expect(SubtitleDownloadError.notPermitted.errorDescription?.contains("download limit") == false)
        #expect(SubtitleDownloadError.timedOut.errorDescription?.contains("download limit") == false)
    }

    @Test func theServersOwnExplanationBeatsOneInventedHere() {
        // Jellyfin wraps a provider exception in a 500 with the real reason
        // in the body. Show that instead of guessing.
        let quota = JellyfinError.server(
            status: 500,
            message: "OpenSubtitles download limit reached for today"
        )
        let classified = SubtitleDownloadError.classify(quota)
        #expect(classified == .reported(status: 500, message: "OpenSubtitles download limit reached for today"))
        #expect(classified.localizedDescription.contains("download limit reached"))
        #expect(classified != .providerUnavailable)

        // Statuses we understand keep our own, actionable wording.
        #expect(SubtitleDownloadError.classify(
            JellyfinError.server(status: 403, message: "Forbidden")) == .notPermitted)
        #expect(SubtitleDownloadError.classify(
            JellyfinError.server(status: 401, message: "Unauthorized")) == .sessionExpired)

        // A reported 5xx is still transient; a reported 4xx is not.
        #expect(SubtitleDownloadError.reported(status: 503, message: "busy").isRetryable)
        #expect(!SubtitleDownloadError.reported(status: 400, message: "bad request").isRetryable)
    }

    @Test func aBodyCarryingResponseIsStillRecognisedByItsStatus() {
        // A 404 with a body is not `.server(404)`, so callers that key off 404
        // must branch on the status, not on case equality.
        let bare = SubtitleDownloadError.classify(JellyfinError.server(status: 404))
        let withBody = SubtitleDownloadError.classify(
            JellyfinError.server(status: 404, message: "Item not found"))
        #expect(bare.httpStatus == 404)
        #expect(withBody.httpStatus == 404)
        #expect(bare != withBody)
    }

    @Test func onlyBodiesThatSaySomethingAreShown() {
        let json = Data(#"{"detail":"Provider returned no results","status":500}"#.utf8)
        #expect(JellyfinClient.serverMessage(from: json) == "Provider returned no results")

        let plain = Data("  Download limit reached\n".utf8)
        #expect(JellyfinClient.serverMessage(from: plain) == "Download limit reached")

        // A real Jellyfin 403 is an HTML page; never show it.
        #expect(JellyfinClient.serverMessage(from: Data("<html><body>no</body></html>".utf8)) == nil)
        #expect(JellyfinClient.serverMessage(from: Data()) == nil)

        // Long bodies are truncated rather than filling the screen.
        let long = JellyfinClient.serverMessage(from: Data(String(repeating: "x", count: 400).utf8))
        #expect((long?.count ?? 0) <= 181)
    }

    @Test func subtitleRetriesOnlyCoverFastFailingTransientErrors() {
        // Retrying a 90 s timeout would leave a spinner up for minutes, and
        // retrying a rate limit inside seconds only spends more quota.
        #expect(SubtitleDownloadError.offline.isRetryable)
        #expect(SubtitleDownloadError.providerUnavailable.isRetryable)
        #expect(!SubtitleDownloadError.timedOut.isRetryable)
        #expect(!SubtitleDownloadError.rateLimited.isRetryable)
        #expect(!SubtitleDownloadError.notPermitted.isRetryable)
        #expect(!SubtitleDownloadError.sessionExpired.isRetryable)
        #expect(!SubtitleDownloadError.unsupportedFile.isRetryable)

        #expect(SubtitleRetryPolicy.shouldRetry(.offline, afterAttempt: 1))
        #expect(SubtitleRetryPolicy.shouldRetry(.offline, afterAttempt: 2))
        #expect(!SubtitleRetryPolicy.shouldRetry(.offline, afterAttempt: 3))
        #expect(!SubtitleRetryPolicy.shouldRetry(.notPermitted, afterAttempt: 1))
    }

    @Test @MainActor func aPermissionFailureOutranksWhicheverLanguageFailedFirst() {
        // Concurrent language searches complete out of order; a 403 explains
        // every sibling failure, so it must not be masked by a stray timeout.
        #expect(SubtitleSearchCoordinator.mostActionable([.timedOut, .notPermitted]) == .notPermitted)
        #expect(SubtitleSearchCoordinator.mostActionable([.server(500), .sessionExpired]) == .sessionExpired)
        #expect(SubtitleSearchCoordinator.mostActionable([.timedOut, .offline]) == .timedOut)
        #expect(SubtitleSearchCoordinator.mostActionable([]) == nil)
    }

    @Test func subtitleManagementOnlyBlocksWhenTheAnswerIsKnown() throws {
        let decode = { (json: String) in
            try JellyfinClient.decoder.decode(UserPolicy.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"EnableSubtitleManagement": true}"#).allowsSubtitleManagement)

        // The only case that blocks: told no, and not an administrator.
        #expect(try !decode(#"{"IsAdministrator": false, "EnableSubtitleManagement": false}"#).allowsSubtitleManagement)
        #expect(try !decode(#"{"EnableSubtitleManagement": false}"#).allowsSubtitleManagement)

        // Administrators pass regardless. Jellyfin hides the checkbox for
        // them, so their stored value is often false.
        #expect(try decode(#"{"IsAdministrator": true, "EnableSubtitleManagement": false}"#).allowsSubtitleManagement)
        #expect(try decode(#"{"IsAdministrator": true}"#).allowsSubtitleManagement)

        // Unknown is not a denial; the server answers 403 if it disagrees.
        #expect(try decode(#"{}"#).allowsSubtitleManagement)
        #expect(try decode(#"{"IsAdministrator": false}"#).allowsSubtitleManagement)
    }

    @Test @MainActor func downloadedSubtitleWaitsForRefreshAndMatchesRequestedLanguage() async throws {
        let stale = try playbackInfo(#"""
        { "MediaSources": [{
          "Id": "source-1",
          "MediaStreams": [
            { "Type": "Subtitle", "Index": 2, "Language": "eng", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/2/0/Stream.vtt" }
          ]
        }]}
        """#)
        let refreshed = try playbackInfo(#"""
        { "MediaSources": [{
          "Id": "source-1",
          "MediaStreams": [
            { "Type": "Subtitle", "Index": 2, "Language": "eng", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/2/0/Stream.vtt" },
            { "Type": "Subtitle", "Index": 3, "Language": "fra", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/3/0/Stream.vtt" },
            { "Type": "Subtitle", "Index": 4, "Language": "eng", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/4/0/Stream.vtt" }
          ]
        }]}
        """#)
        let existingStream = try #require(stale.mediaSources.first?.mediaStreams?.first)
        var fetchCount = 0
        let poller = DownloadedSubtitlePoller(refreshDelays: [.zero, .zero])

        let stream = try await poller.waitForStream(
            mediaSourceID: "source-1",
            existingSignatures: [SubtitleStreamSignature(existingStream)],
            requestedLanguage: "eng"
        ) {
            fetchCount += 1
            return fetchCount == 1 ? stale : refreshed
        }

        #expect(fetchCount == 2)
        #expect(stream.index == 4)
        #expect(stream.language == "eng")
    }

    @Test @MainActor func downloadedSubtitleTimeoutHasSubtitleSpecificError() async throws {
        let stale = try playbackInfo(#"""
        { "MediaSources": [{ "Id": "source-1", "MediaStreams": [] }] }
        """#)
        let poller = DownloadedSubtitlePoller(refreshDelays: [.zero])

        do {
            _ = try await poller.waitForStream(
                mediaSourceID: "source-1",
                existingSignatures: [],
                requestedLanguage: "eng"
            ) { stale }
            Issue.record("Expected the subtitle refresh to time out")
        } catch let error as SubtitleDownloadError {
            #expect(error.errorDescription?.contains("subtitle") == true)
            #expect(error.errorDescription?.contains("device") == false)
        }
    }

    @Test @MainActor func preferencesStayScopedToTheirServerAccount() {
        let suiteName = "SubtitleWorkflowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SubtitlePreferencesStore(defaults: defaults)
        first.configure(accountID: "server-a:user")
        first.setPrimaryLanguage("et")
        var values = first.values
        values.edgeStyle = .outline
        values.followsSystemAppearance = false
        first.values = values

        let second = SubtitlePreferencesStore(defaults: defaults)
        second.configure(accountID: "server-b:user")
        #expect(second.values.followsSystemAppearance)
        #expect(second.values.languageOverrides.isEmpty)

        let restored = SubtitlePreferencesStore(defaults: defaults)
        restored.configure(accountID: "server-a:user")
        #expect(restored.values.languageOverrides.first == "et")
        #expect(restored.values.edgeStyle == .outline)
    }

    @Test func assResetOnlyClearsTheOverridesBeforeIt() throws {
        // Override tags apply left to right, so `{\i1\r}` ends up plain.
        let resetLast = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\b1\i1\r}Plain"#
        ))
        #expect(resetLast.usesDefaultStyle)

        let resetFirst = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\r\i1}Italic"#
        ))
        #expect(resetFirst.runs.first?.isItalic == true)
        #expect(resetFirst.runs.first?.isBold == false)

        // A reset keeps the alignment; placement is not an inline style.
        let placed = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\an8\b1\r}Top"#
        ))
        #expect(placed.alignment == .topCenter)
        #expect(placed.usesDefaultStyle)
    }

    @Test func ordinaryASSDialogueKeepsTheLegacyBottomCentrePresentation() throws {
        let cue = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,Hello\Nworld"#
        ))
        #expect(cue.text == "Hello\nworld")
        #expect(cue.usesDefaultPlacement)
        #expect(cue.usesDefaultStyle)
    }

    @Test @MainActor func downloadedSubtitleIsInsertedAndSelectedAtRuntime() async throws {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.addExternalSubtitle(ExternalSubtitleTrack(
            url: URL(string: "https://example.invalid/subtitle.vtt")!,
            preloadedData: Data("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nHello\n".utf8),
            title: "English SDH",
            language: "eng",
            select: true,
            isHearingImpaired: true,
            isDownloaded: true
        ))
        #expect(engine.subtitleTracks.count == 1)
        try await waitUntil { engine.subtitleTracks[0].isSelected }
        #expect(engine.subtitleTracks[0].isSelected)
        #expect(engine.subtitleTracks[0].source == .downloaded)
        #expect(engine.subtitleTracks[0].isHearingImpaired)
    }

    @Test @MainActor func remoteSubtitleUserFlowDownloadsValidCuesAndActivatesTrack() async throws {
        SubtitleDownloadFixture.reset()
        StubURLProtocol.register(host: "subtitle.test", handler: SubtitleDownloadFixture.respond)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "subtitle.test", deviceId: "subtitle-download-test", token: "test-token", userId: "user-1"
        )

        let engine = SampleBufferPlayerEngine()
        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        let addedStreams = AddedStreams()
        coordinator.configure(
            client: client,
            engine: engine,
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { addedStreams.streams.append($0) }
        )

        // The same sequence as the in-player Find Subtitles button.
        coordinator.startSearch()
        try await waitUntil { !coordinator.results.isEmpty }
        let result = try #require(coordinator.results.first)
        coordinator.startDownload(result)
        try await waitUntil { coordinator.phase == .downloaded }
        // No server stream exists yet, but the controller needs one entry per
        // engine track to carry the choice into the next episode.
        let added = try #require(addedStreams.streams.first)
        #expect(addedStreams.streams.count == 1)
        #expect(added.type == "Subtitle")
        #expect(added.language == "eng")
        #expect(added.displayTitle == result.name)
        #expect(added.isExternal == true)
        #expect(added.isHearingImpaired == true)
        try await waitUntil {
            SubtitleDownloadFixture.requests.contains {
                $0.method == "POST" && $0.path == "/Videos/item-1/Subtitles"
            }
        }

        try await waitUntil { engine.subtitleTracks.first?.isSelected == true }
        let track = try #require(engine.subtitleTracks.first)
        #expect(track.isSelected)
        #expect(track.source == .downloaded)
        #expect(track.languageTag == "eng")
        #expect(track.isHearingImpaired)

        let requests = SubtitleDownloadFixture.requests
        #expect(requests.contains {
            $0.method == "GET"
                && $0.path == "/Items/item-1/RemoteSearch/Subtitles/eng"
        })
        #expect(requests.contains {
            $0.method == "GET"
                && $0.percentEncodedPath
                    == "/Providers/Subtitles/Subtitles/srt-eng-42%2Fprovider%3Fpart%23100%25"
                && $0.query == nil
        })
        let upload = try #require(requests.first {
            $0.method == "POST" && $0.path == "/Videos/item-1/Subtitles"
        })
        #expect(upload.body?.contains(#""Format":"vtt""#) == true)
        #expect(upload.body?.contains(#""Language":"eng""#) == true)
        #expect(upload.body?.contains(#""IsHearingImpaired":true"#) == true)
        #expect(!requests.contains {
            $0.method == "POST" && $0.path.contains("RemoteSearch/Subtitles")
        })
        #expect(requests.allSatisfy { $0.authorization?.contains(#"Token="test-token""#) == true })
    }

    @Test @MainActor func remoteSubtitleSearchKeepsResultsWhenAnotherLanguageFails() async throws {
        SubtitleDownloadFixture.reset()
        StubURLProtocol.register(host: "subtitle.test", handler: SubtitleDownloadFixture.respond)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "subtitle.test", deviceId: "subtitle-search-test", token: "test-token", userId: "user-1"
        )

        let coordinator = SubtitleSearchCoordinator()
        coordinator.configure(
            client: client,
            engine: SampleBufferPlayerEngine(),
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["fr", "en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        coordinator.startSearch()
        try await waitUntil { coordinator.phase != .searching }

        #expect(coordinator.phase == .idle)
        #expect(coordinator.results.count == 2)
        #expect(SubtitleDownloadFixture.requests.contains {
            $0.path == "/Items/item-1/RemoteSearch/Subtitles/fra"
        })
        #expect(SubtitleDownloadFixture.requests.contains {
            $0.path == "/Items/item-1/RemoteSearch/Subtitles/eng"
        })
    }

    @Test @MainActor func anAccountWithoutSubtitleManagementIsToldSoBeforeAnyRequest() async throws {
        SubtitleDownloadFixture.reset(subtitleManagement: false)
        StubURLProtocol.register(host: "subtitle.test", handler: SubtitleDownloadFixture.respond)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "subtitle.test", deviceId: "subtitle-permission-test", token: "test-token", userId: "user-1"
        )

        let coordinator = SubtitleSearchCoordinator()
        coordinator.configure(
            client: client,
            engine: SampleBufferPlayerEngine(),
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en", "fr"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        coordinator.startSearch()
        try await waitUntil { coordinator.phase != .searching }

        // Jellyfin answers 403 to every remote subtitle endpoint without this
        // permission, so check once and spend no provider request.
        #expect(coordinator.phase == .notPermitted)
        #expect(coordinator.results.isEmpty)
        #expect(!SubtitleDownloadFixture.requests.contains {
            $0.path.contains("RemoteSearch")
        })
    }

    @Test @MainActor func aForbiddenProviderFetchNeverRetriesThroughJellyfin() async throws {
        SubtitleDownloadFixture.reset()
        StubURLProtocol.register(host: "subtitle.test", handler: SubtitleDownloadFixture.respond)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "subtitle.test", deviceId: "subtitle-forbidden-test", token: "test-token", userId: "user-1"
        )

        let engine = SampleBufferPlayerEngine()
        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        coordinator.configure(
            client: client,
            engine: engine,
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        let forbidden = try JellyfinClient.decoder.decode(
            RemoteSubtitleInfo.self,
            from: Data(#"{ "Id": "forbidden-file", "Name": "Forbidden", "ThreeLetterISOLanguageName": "eng", "ProviderName": "Test Provider", "Format": "srt" }"#.utf8)
        )
        coordinator.startDownload(SubtitleCandidate(forbidden))
        try await waitUntil { coordinator.phase == .notPermitted }

        // Jellyfin's save path refetches from the provider; after a 403 that
        // only spends quota.
        #expect(!SubtitleDownloadFixture.requests.contains {
            $0.method == "POST" && $0.path.contains("RemoteSearch")
        })
        #expect(engine.subtitleTracks.isEmpty)
    }

    @Test @MainActor func missingProviderFileExplainsRemovalOrDownloadLimit() async throws {
        SubtitleDownloadFixture.reset()
        StubURLProtocol.register(host: "subtitle.test", handler: SubtitleDownloadFixture.respond)
        let client = StubURLProtocol.makeJellyfinClient(
            host: "subtitle.test", deviceId: "subtitle-failure-test", token: "test-token", userId: "user-1"
        )

        let engine = SampleBufferPlayerEngine()
        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        coordinator.configure(
            client: client,
            engine: engine,
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        coordinator.startSearch()
        try await waitUntil { coordinator.results.count == 2 }
        // Candidate ids are namespaced by source, so match on providerID.
        let missing = try #require(coordinator.results.first { $0.providerID == "missing-provider-file" })
        coordinator.startDownload(missing)
        try await waitUntil {
            if case .downloadFailed = coordinator.phase { return true }
            return false
        }

        guard case .downloadFailed(let message) = coordinator.phase else {
            Issue.record("Expected a provider-specific download failure")
            return
        }
        #expect(message.contains("removed"))
        #expect(message.contains("download limit"))
        #expect(engine.subtitleTracks.isEmpty)
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        try await Polling.untilMainActor(
            timeout: .milliseconds(attempts * 10), pollInterval: .milliseconds(10), condition: condition
        )
        if !condition() {
            Issue.record("Timed out waiting for the subtitle workflow")
        }
    }

    private func playbackInfo(_ json: String) throws -> PlaybackInfoResponse {
        try JellyfinClient.decoder.decode(PlaybackInfoResponse.self, from: Data(json.utf8))
    }
}

private nonisolated struct RecordedSubtitleRequest: Sendable {
    let method: String
    let path: String
    let percentEncodedPath: String
    let query: String?
    let authorization: String?
    let body: String?
}

/// Fixture state for the subtitle-download flow tests: a fake Jellyfin
/// transport where PlaybackInfo stays stale, so the coordinator must fetch
/// and parse the provider's bytes before activating the track. The body is
/// read once at request time (URLRequest's body stream can only be drained
/// once), so it is captured into the recorded request rather than re-read
/// later from the stub's own request log.
private enum SubtitleDownloadFixture {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedRequests: [RecordedSubtitleRequest] = []
    private nonisolated(unsafe) static var userPolicyPayload = #"{ "Id": "user-1", "Name": "Tester", "Policy": { "IsAdministrator": false, "EnableSubtitleManagement": true } }"#

    static var requests: [RecordedSubtitleRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func reset(subtitleManagement: Bool = true) {
        lock.lock()
        recordedRequests = []
        userPolicyPayload = #"{ "Id": "user-1", "Name": "Tester", "Policy": { "IsAdministrator": false, "EnableSubtitleManagement": \#(subtitleManagement) } }"#
        lock.unlock()
    }

    static func respond(to request: URLRequest) throws -> (Int, [String: String], Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let percentEncodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath ?? url.path

        lock.lock()
        recordedRequests.append(RecordedSubtitleRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            percentEncodedPath: percentEncodedPath,
            query: url.query,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: bodyString(from: request)
        ))
        let policyPayload = userPolicyPayload
        lock.unlock()

        let payload: Data
        let status: Int
        switch (request.httpMethod ?? "GET", percentEncodedPath) {
        case ("GET", "/Items/item-1/RemoteSearch/Subtitles/eng"):
            payload = Data(#"""
            [{
              "Id": "srt-eng-42/provider?part#100%",
              "Name": "English provider subtitle",
              "ThreeLetterISOLanguageName": "eng",
              "ProviderName": "Test Provider",
              "Format": "vtt",
              "HearingImpaired": true
            }, {
              "Id": "missing-provider-file",
              "Name": "Deleted provider subtitle",
              "ThreeLetterISOLanguageName": "eng",
              "ProviderName": "Test Provider",
              "Format": "srt"
            }]
            """#.utf8)
            status = 200
        case ("GET", "/Items/item-1/RemoteSearch/Subtitles/fra"):
            payload = Data()
            status = 500
        case ("POST", "/Items/item-1/PlaybackInfo"):
            payload = Data(#"{ "MediaSources": [{ "Id": "source-1", "MediaStreams": [] }] }"#.utf8)
            status = 200
        case ("GET", "/Providers/Subtitles/Subtitles/srt-eng-42%2Fprovider%3Fpart%23100%25"):
            payload = Data(#"""
            WEBVTT

            00:00:00.000 --> 00:00:02.000
            Downloaded subtitle cue
            """#.utf8)
            status = 200
        case ("GET", "/Providers/Subtitles/Subtitles/missing-provider-file"):
            payload = Data()
            status = 404
        case ("GET", "/Providers/Subtitles/Subtitles/forbidden-file"):
            payload = Data()
            status = 403
        case ("GET", "/Users/Me"):
            payload = Data(policyPayload.utf8)
            status = 200
        case ("POST", "/Items/item-1/RemoteSearch/Subtitles/missing-provider-file"):
            // Jellyfin 10.11 returns 204 even when its internal provider
            // operation throws; PlaybackInfo remains stale below.
            payload = Data()
            status = 204
        case ("POST", "/Videos/item-1/Subtitles"):
            payload = Data()
            status = 204
        default:
            payload = Data()
            status = 404
        }

        let headers = ["Content-Type": url.path.hasPrefix("/Providers/Subtitles/Subtitles/") && status == 200
                      ? "application/x-subrip" : "application/json"]
        return (status, headers, payload)
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
private final class AddedStreams {
    var streams: [MediaStream] = []
}
