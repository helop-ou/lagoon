import Foundation
import Testing
import UIKit
@testable import Lagoon

@Suite("Bounded downloads and subtitle replacement", .serialized)
@MainActor
struct DownloadHardeningTests {
    @Test(arguments: [401, 403, 404, 500])
    func statusFailuresCannotBecomeSubtitleContent(status: Int) async throws {
        let downloader = makeDownloader()
        DownloadProtocol.set("/file", .init(status: status, chunks: [Self.cues("Not a successful response")]))
        do {
            _ = try await downloader.data(from: Self.url("/file"), limit: 1024, content: .subtitle)
            Issue.record("HTTP failures must not become subtitle bytes")
        } catch DownloadFailure.httpStatus(let actual, _) { #expect(actual == status) }
    }

    @Test func headerLimitsRejectBeforeWaitingForTheBody() async throws {
        let downloader = makeDownloader()
        DownloadProtocol.set("/large", .init(headers: ["Content-Length": "1000000000"], holdBody: true))
        do {
            _ = try await downloader.data(from: Self.url("/large"), limit: 1024, content: .image)
            Issue.record("Declared oversize response should fail immediately")
        } catch DownloadFailure.tooLarge(let limit) { #expect(limit == 1024) }
        try await eventually { DownloadProtocol.stopped.contains("/large") }
    }

    @Test(arguments: [[:], ["Content-Length": "1"], ["Content-Encoding": "gzip"]])
    func receivedBytesAreBoundedRegardlessOfLengthMetadata(headers: [String: String]) async throws {
        let downloader = makeDownloader()
        DownloadProtocol.set("/large", .init(headers: headers, chunks: [Data(repeating: 65, count: 513), Data(repeating: 66, count: 512)]))
        do {
            _ = try await downloader.data(from: Self.url("/large"), limit: 1024, content: .subtitle)
            Issue.record("Every received chunk must respect the byte cap")
        } catch DownloadFailure.tooLarge(let limit) { #expect(limit == 1024) }
    }

    @Test func exactLimitSucceedsButTruncationAndHTMLDoNot() async throws {
        let downloader = makeDownloader()
        let bytes = Data(repeating: 65, count: 1024)
        DownloadProtocol.set("/exact", .init(headers: ["Content-Length": "1024"], chunks: [bytes]))
        #expect(try await downloader.data(from: Self.url("/exact"), limit: 1024, content: .bytes) == bytes)
        DownloadProtocol.set("/short", .init(headers: ["Content-Length": "1024"], chunks: [Data([1])]))
        do {
            _ = try await downloader.data(from: Self.url("/short"), limit: 1024, content: .image)
            Issue.record("Truncated responses must not be decoded")
        } catch DownloadFailure.truncated {}
        DownloadProtocol.set("/html", .init(headers: ["Content-Type": "text/html"], holdBody: true))
        do {
            _ = try await downloader.data(from: Self.url("/html"), limit: 1024, content: .subtitle)
            Issue.record("HTML should be rejected before reading a body")
        } catch DownloadFailure.unexpectedContentType {}
    }

    @Test func cancellationStopsAnActiveTransferAndAPrecancelledTaskDoesNotStartOne() async throws {
        let downloader = makeDownloader()
        DownloadProtocol.set("/held", .init(holdBody: true))
        let pending = Task { try await downloader.data(from: Self.url("/held"), limit: 1024, content: .bytes) }
        try await eventually { DownloadProtocol.requests.count == 1 }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        try await eventually { DownloadProtocol.stopped.contains("/held") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await downloader.data(from: Self.url("/never"), limit: 1024, content: .bytes)
        }
        do { _ = try await cancelled.value; Issue.record("Expected pre-cancellation") } catch is CancellationError {}
        #expect(DownloadProtocol.requests.count == 1)
    }

    @Test func rangeIgnoredByServerCannotDownloadAnEntireMovieForASubtitleHash() async throws {
        _ = makeDownloader()
        DownloadProtocol.set("/movie", .init(headers: ["Content-Length": "1000000000"], chunks: [Data(repeating: 0, count: 32_768)], holdBody: false))
        let config = configuration()
        let reader = MovieHashReader(session: URLSession(configuration: config))
        #expect(await reader.hash(of: Self.url("/movie"), fileSize: 1_000_000) == nil)
    }

    @Test func boundedJellyfinProviderRequestsPreserveMessagesAndExpireTheCorrectSession() async throws {
        _ = makeDownloader()
        let client = JellyfinClient(deviceId: "fixture", sessionConfiguration: configuration())
        client.configure(serverURL: Self.url(""))
        client.activateSession(token: "synthetic", userId: "viewer")
        var expired: JellyfinClient.SessionIdentity?
        client.onSessionExpired = { expired = $0 }
        DownloadProtocol.set("/Providers/Subtitles/Subtitles/missing", .init(status: 500, chunks: [Data(#"{"message":"Provider maintenance"}"#.utf8)]))
        do {
            _ = try await client.remoteSubtitleFile(subtitleId: "missing")
            Issue.record("Expected provider error")
        } catch JellyfinError.server(let status, let message) {
            #expect(status == 500)
            #expect(message == "Provider maintenance")
        }
        DownloadProtocol.set("/Providers/Subtitles/Subtitles/expired", .init(status: 401, holdBody: true))
        do { _ = try await client.remoteSubtitleFile(subtitleId: "expired"); Issue.record("Expected expiry") }
        catch JellyfinError.sessionExpired {}
        #expect(client.accessToken == nil)
        #expect(expired?.userId == "viewer")
        #expect(DownloadProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("synthetic") == true })
    }

    @Test func subtitleValidationRejectsOversizeHTMLAndInvalidTimingButKeepsValidText() async throws {
        do { _ = try await ExternalSubtitleLoader.parse(Data(repeating: 65, count: DownloadLimit.subtitle + 1), language: nil); Issue.record("Expected byte cap") }
        catch SubtitleDownloadError.tooLarge {}
        do { _ = try await ExternalSubtitleLoader.parse(Data("<html>\n\n1\n00:00:00,000 --> 00:00:10,000\nLogin page\n</html>".utf8), language: nil); Issue.record("Expected HTML rejection") }
        catch SubtitleDownloadError.invalidFile {}
        #expect(SubtitleParser.cues(from: Data("1\n00:00:00,000 --> 00:00:inf\nBad cue".utf8)).isEmpty)
        #expect(try await ExternalSubtitleLoader.parse(Self.cues("Valid cue"), language: "en").first?.text == "Valid cue")
    }

    @Test func aProviderDownloadCannotOverrideANewerTrackChoice() async throws {
        let downloader = makeDownloader()
        let client = JellyfinClient(deviceId: "fixture", sessionConfiguration: configuration())
        client.configure(serverURL: Self.url(""))
        client.activateSession(token: "synthetic", userId: "viewer")
        DownloadProtocol.set("/Users/Me", .init(chunks: [Data(#"{"Id":"viewer","Policy":{"EnableSubtitleManagement":true}}"#.utf8)]))
        let path = "/Providers/Subtitles/Subtitles/held"
        DownloadProtocol.set(path, .init(chunks: [Self.cues("Late provider captions")], holdBody: true))
        let engine = SampleBufferPlayerEngine(subtitleDownloader: downloader)
        let coordinator = SubtitleSearchCoordinator()
        defer { coordinator.detach(); engine.shutdown() }
        coordinator.configure(client: client, engine: engine, itemID: "fixture", mediaSourceID: "source", streams: [],
                              preferredLanguages: ["en"], missingMode: .ask, hasSuitableLocalTrack: true, onTrackAdded: { _ in })
        let result = try JellyfinClient.decoder.decode(RemoteSubtitleInfo.self, from: Data(#"{"Id":"held","Format":"srt"}"#.utf8))
        coordinator.startDownload(SubtitleCandidate(result))
        try await eventually { DownloadProtocol.isHeld(path) }
        engine.selectSubtitleTrack(id: nil)
        DownloadProtocol.release(path)
        try await eventually { coordinator.phase == .idle }
        #expect(engine.subtitleTracks.isEmpty)
        #expect(engine.currentSubtitleText == nil)
    }

    @Test func aLateProvider401CannotExpireTheNextJellyfinAccount() async throws {
        _ = makeDownloader()
        let client = JellyfinClient(deviceId: "fixture", sessionConfiguration: configuration())
        client.configure(serverURL: Self.url(""))
        client.activateSession(token: "old", userId: "old")
        var expiryCount = 0
        client.onSessionExpired = { _ in expiryCount += 1 }
        let path = "/Providers/Subtitles/Subtitles/late"
        DownloadProtocol.set(path, .init(status: 401, holdResponse: true))
        let request = Task { try await client.remoteSubtitleFile(subtitleId: "late") }
        try await eventually { DownloadProtocol.isHeld(path) }
        client.activateSession(token: "new", userId: "new")
        DownloadProtocol.release(path)
        do { _ = try await request.value; Issue.record("Old request should be invalidated") }
        catch is CancellationError {}
        #expect(client.accessToken == "new")
        #expect(expiryCount == 0)
    }

    @Test func failedReplacementKeepsWorkingCaptionsAndRetryCommitsOnlyAfterSuccess() async throws {
        let downloader = makeDownloader()
        let engine = SampleBufferPlayerEngine(subtitleDownloader: downloader)
        defer { engine.shutdown() }
        engine.addExternalSubtitle(Self.track("working", data: Self.cues("Working captions")))
        try await eventually { engine.subtitleTracks.first?.isSelected == true }
        #expect(engine.currentSubtitleText == "Working captions")
        DownloadProtocol.set("/replacement", .init(status: 404, chunks: [Data()]))
        engine.addExternalSubtitle(Self.track("replacement"))
        try await eventually { if case .failed = engine.subtitleLoadState { true } else { false } }
        #expect(engine.subtitleTracks.first?.isSelected == true)
        #expect(engine.subtitleTracks.last?.isSelected == false)
        #expect(engine.currentSubtitleText == "Working captions")
        DownloadProtocol.set("/replacement", .init(chunks: [Self.cues("Replacement captions")], holdBody: true))
        engine.retrySubtitleLoad()
        try await eventually { DownloadProtocol.requests.count == 2 }
        #expect(engine.currentSubtitleText == "Working captions")
        DownloadProtocol.release("/replacement")
        try await eventually { engine.subtitleLoadState == .idle }
        #expect(engine.currentSubtitleText == "Replacement captions")
        #expect(engine.subtitleTracks.last?.isSelected == true)
    }

    @Test func offNewSelectionAndShutdownCancelPendingSubtitlesWithoutLateReplacement() async throws {
        let downloader = makeDownloader()
        let engine = SampleBufferPlayerEngine(subtitleDownloader: downloader)
        defer { engine.shutdown() }
        DownloadProtocol.set("/slow", .init(chunks: [Self.cues("Stale captions")], holdBody: true))
        engine.addExternalSubtitle(Self.track("slow"))
        try await eventually { DownloadProtocol.requests.count == 1 }
        engine.addExternalSubtitle(Self.track("new", data: Self.cues("New captions")))
        try await eventually { engine.subtitleTracks.last?.isSelected == true }
        try await eventually { DownloadProtocol.stopped.contains("/slow") }
        DownloadProtocol.release("/slow")
        #expect(engine.currentSubtitleText == "New captions")
        engine.selectSubtitleTrack(id: 1)
        try await eventually { DownloadProtocol.requests.count == 2 }
        engine.selectSubtitleTrack(id: nil)
        #expect(engine.currentSubtitleText == nil)
        #expect(engine.subtitleLoadState == .idle)
        #expect(engine.subtitleTracks.allSatisfy { !$0.isSelected })
        engine.selectSubtitleTrack(id: 1)
        try await eventually { DownloadProtocol.requests.count == 3 }
        engine.shutdown()
        DownloadProtocol.release("/slow")
        #expect(engine.subtitleLoadState == .idle)
        #expect(engine.currentSubtitleText == nil)
    }

    @Test func sharedArtworkCancelsOnlyWhenItsLastViewerLeavesAndCachesOnlyValidImages() async throws {
        let downloader = makeDownloader()
        let cache = ImageCache(downloader: downloader)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        DownloadProtocol.set("/image", .init(chunks: [png], holdBody: true))
        var firstFinished = false
        let first = Task { let result = await cache.load(Self.url("/image"), maxPixelSize: 16); firstFinished = true; return result }
        var secondStarted = false
        let second = Task { secondStarted = true; return await cache.load(Self.url("/image"), maxPixelSize: 16) }
        defer { first.cancel(); second.cancel() }
        try await eventually { DownloadProtocol.requests.count == 1 && secondStarted }
        first.cancel()
        try await eventually { firstFinished }
        #expect(await first.value == nil)
        #expect(!DownloadProtocol.stopped.contains("/image"))
        DownloadProtocol.release("/image")
        let image = try #require(await second.value)
        #expect(image.size.width == 16)
        #expect(cache.image(for: Self.url("/image"), maxPixelSize: 16) != nil)
        #expect(DownloadProtocol.requests.count == 1)
        DownloadProtocol.set("/cancel", .init(holdBody: true))
        let last = Task { await cache.load(Self.url("/cancel"), maxPixelSize: 16) }
        try await eventually { DownloadProtocol.requests.count == 2 }
        last.cancel()
        #expect(await last.value == nil)
        try await eventually { DownloadProtocol.stopped.contains("/cancel") }
        DownloadProtocol.set("/broken", .init(chunks: [Data(png.prefix(png.count / 2))]))
        #expect(await cache.load(Self.url("/broken"), maxPixelSize: 16) == nil)
        #expect(cache.image(for: Self.url("/broken"), maxPixelSize: 16) == nil)
        DownloadProtocol.set("/broken", .init(chunks: [png]))
        #expect(await cache.load(Self.url("/broken"), maxPixelSize: 16) != nil)
    }

    private func makeDownloader() -> BoundedDownload {
        DownloadProtocol.reset()
        return BoundedDownload(configuration: configuration())
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadProtocol.self]
        return config
    }
    private static func url(_ path: String) -> URL { URL(string: "https://media.download.test" + path)! }
    private static func cues(_ text: String) -> Data { Data("1\n00:00:00,000 --> 00:10:00,000\n\(text)\n".utf8) }
    private static func track(_ path: String, data: Data? = nil) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: url("/" + path), preloadedData: data, title: path, language: "en", select: true)
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the observable result")
        throw URLError(.timedOut)
    }
}

private nonisolated struct DownloadFixture: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var holdBody = false
    var holdResponse = false
}

private nonisolated final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: DownloadFixture] = [:]
    private nonisolated(unsafe) static var recorded: [URLRequest] = []
    private nonisolated(unsafe) static var cancelled: [String] = []
    private nonisolated(unsafe) static var held: [DownloadProtocol] = []
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture = DownloadFixture()
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var stopped: [String] { lock.withLock { cancelled } }
    static func isHeld(_ path: String) -> Bool { lock.withLock { held.contains { $0.request.url?.path == path } } }
    static func reset() { lock.withLock { fixtures = [:]; recorded = []; cancelled = []; held = [] } }
    static func set(_ path: String, _ fixture: DownloadFixture) { lock.withLock { fixtures[path] = fixture } }
    static func release(_ path: String) {
        let pending = lock.withLock {
            let pending = held.filter { $0.request.url?.path == path }
            held.removeAll { $0.request.url?.path == path }
            return pending
        }
        for item in pending {
            if item.fixture.holdResponse { item.deliverResponse() }
            item.deliverBody()
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "media.download.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        fixture = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.fixtures[url.path] ?? DownloadFixture(status: 404)
        }
        if fixture.holdResponse {
            Self.lock.withLock { Self.held.append(self) }
            return
        }
        deliverResponse()
        if fixture.holdBody { Self.lock.withLock { Self.held.append(self) } }
        else { deliverBody() }
    }
    private func deliverResponse() {
        guard let url = request.url else { return }
        // Without a MIME type Foundation may wait for body bytes to sniff
        // content before forwarding the response to its session delegate.
        let headers = ["Content-Type": "application/octet-stream"].merging(fixture.headers) { _, supplied in supplied }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
    }
    private func deliverBody() {
        guard !stateLock.withLock({ stopped }) else { return }
        for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        stateLock.withLock { stopped = true }
        Self.lock.withLock {
            Self.cancelled.append(request.url?.path ?? "")
            Self.held.removeAll { $0 === self }
        }
    }
}
