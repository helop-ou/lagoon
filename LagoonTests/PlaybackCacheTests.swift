import Foundation
import Testing
@testable import Lagoon

@Suite("Playback cache", .serialized)
struct PlaybackCacheTests {
    @Test func directFilesUseCachedTransportWhileReleaseHLSStaysNative() {
        let suiteName = "PlaybackCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PlaybackBufferPolicy.customIOEnabled(for: .directPlay, defaults: defaults))
        #expect(PlaybackBufferPolicy.customIOEnabled(for: .directStream, defaults: defaults))
        #expect(!PlaybackBufferPolicy.customIOEnabled(for: .transcode, defaults: defaults))
        defaults.set(true, forKey: "debug.experimentalPlaybackCache")
        #if DEBUG
        #expect(PlaybackBufferPolicy.customIOEnabled(for: .transcode, defaults: defaults))
        #else
        #expect(!PlaybackBufferPolicy.customIOEnabled(for: .transcode, defaults: defaults))
        #endif
    }

    @Test func adaptiveCapacityPreservesFreeSpaceAndHonorsMaximum() {
        let mebibyte: Int64 = 1_024 * 1_024

        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: nil) == 2_048 * mebibyte)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 319 * mebibyte) == 0)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 320 * mebibyte) == 64 * mebibyte)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 1_024 * mebibyte) == 384 * mebibyte)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 4_096 * mebibyte) == 1_920 * mebibyte)
    }

    @Test func rangeLoaderDoesNotRetainItselfThroughItsSessionDelegate() {
        weak var releasedLoader: URLSessionPlaybackRangeLoader?
        do {
            let loader = URLSessionPlaybackRangeLoader()
            releasedLoader = loader
            #expect(releasedLoader != nil)
        }
        #expect(releasedLoader == nil)
    }

    @Test func rangesMergeOverlapAndAdjacencyWithoutDoubleCounting() {
        var ranges = PlaybackByteRangeSet()
        #expect(ranges.insert(PlaybackByteRange(10, 20)) == 10)
        #expect(ranges.insert(PlaybackByteRange(20, 30)) == 10)
        #expect(ranges.insert(PlaybackByteRange(15, 25)) == 0)
        #expect(ranges.ranges == [PlaybackByteRange(10, 30)])
        #expect(ranges.byteCount == 20)
        #expect(ranges.contiguousUpperBound == 0)
        #expect(ranges.contains(PlaybackByteRange(12, 28)))
        #expect(!ranges.contains(PlaybackByteRange(0, 12)))

        #expect(ranges.insert(PlaybackByteRange(0, 10)) == 10)
        #expect(ranges.contiguousUpperBound == 30)
    }

    @Test func boundedPrefetchPublishesProgressAndOnlyCompletesAWholeFile() async throws {
        let payload = Data((0..<96).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-buffered",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        #expect(scope.metrics.bufferedFraction == 0)
        #expect(scope.completeFileURL == nil)
        #expect(await scope.prefetchNextChunk())
        #expect(scope.metrics.contiguousCachedBytes == 32)
        #expect(scope.metrics.bufferedFraction == 1.0 / 3.0)
        #expect(scope.completeFileURL == nil)
        #expect(await scope.prefetchNextChunk())
        #expect(await scope.prefetchNextChunk())
        #expect(scope.metrics.bufferedFraction == 1)
        #expect(scope.completeFileURL == scope.fileURL)
        #expect(!(await scope.prefetchNextChunk()))
    }

    @Test func seekMovesProactiveFillToPlayheadThenWrapsBackWithoutLosingPrefix() async throws {
        let payload = Data((0..<256).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-seek-buffer",
            sourceURL: URL(string: "https://media.test/movie.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        // Establish the ordinary byte-zero prefix, then model FFmpeg's real
        // high-priority range read after a seek to the middle of the file.
        #expect(await scope.prefetchNextChunk())
        #expect(try scope.read(offset: 128, length: 8) == payload.subdata(in: 128..<136))
        #expect(loader.requestedRanges == [
            PlaybackByteRange(0, 32),
            PlaybackByteRange(128, 160),
        ])

        // Proactive traffic must continue after the seek's cached island,
        // not resume at byte 32. Both islands remain visible to the UI.
        #expect(await scope.prefetchNextChunk())
        #expect(loader.requestedRanges.last == PlaybackByteRange(160, 192))
        #expect(scope.metrics.cachedByteRanges == [
            PlaybackByteRange(0, 32),
            PlaybackByteRange(128, 192),
        ])
        #expect(scope.metrics.bufferedRanges == [
            PlaybackBufferedRange(lowerFraction: 0, upperFraction: 0.125),
            PlaybackBufferedRange(lowerFraction: 0.5, upperFraction: 0.75),
        ])
        #expect(scope.metrics.playheadPrefetchCount == 1)

        // Finish playhead-to-EOF first, then verify the scheduler wraps back
        // to the earliest hole and can still promote a complete sparse file.
        #expect(await scope.prefetchNextChunk())
        #expect(loader.requestedRanges.last == PlaybackByteRange(192, 224))
        #expect(await scope.prefetchNextChunk())
        #expect(loader.requestedRanges.last == PlaybackByteRange(224, 256))
        #expect(await scope.prefetchNextChunk())
        #expect(loader.requestedRanges.last == PlaybackByteRange(32, 64))
        while await scope.prefetchNextChunk() {}

        #expect(scope.metrics.cachedByteRanges == [PlaybackByteRange(0, 256)])
        #expect(scope.metrics.bufferedFraction == 1)
        #expect(scope.completeFileURL == scope.fileURL)
    }

    @Test func repeatedReadComesFromSparseFileAndReportsAHit() throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-1",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: 128,
            requestSize: 64,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        let first = try scope.read(offset: 16, length: 8)
        let second = try scope.read(offset: 16, length: 8)

        #expect(first == payload.subdata(in: 16..<24))
        #expect(second == first)
        #expect(loader.requestCount == 1)
        #expect(scope.metrics.networkBytes == 64)
        #expect(scope.metrics.cacheHitBytes == 8)
        #expect(scope.metrics.cachedBytes == 64)
    }

    @Test func diskUsageNeverExceedsTheConfiguredCap() throws {
        let payload = Data(repeating: 0xAB, count: 256)
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-1",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: 32,
            requestSize: 64,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        #expect(try scope.read(offset: 0, length: 16).count == 16)
        #expect(try scope.read(offset: 128, length: 16).count == 16)
        #expect(scope.metrics.cachedBytes == 32)
        #expect(scope.metrics.networkBytes == 128)
    }

    @Test func cancellationStopsRequestsAndRejectsLaterReads() throws {
        let loader = PlaybackCacheLoaderStub(payload: Data(repeating: 1, count: 64))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-cancelled",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: 64,
            directory: directory,
            byteLimit: 64,
            requestSize: 16,
            loader: loader
        )

        scope.cancelAndRemove()

        #expect(loader.wasCancelled)
        do {
            _ = try scope.read(offset: 0, length: 8)
            Issue.record("A cancelled playback scope accepted another read")
        } catch {
            #expect(error as? PlaybackCacheError != nil)
        }
    }

    @Test func ignoredRangeResponseFallsBackBeforeBufferingTheBody() throws {
        PlaybackCacheURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackCacheURLProtocol.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)

        do {
            _ = try loader.load(
                url: URL(string: "https://cache.test/video.mkv")!,
                range: PlaybackByteRange(0, 16),
                priority: URLSessionTask.highPriority
            )
            Issue.record("A whole-body response was accepted as seekable range data")
        } catch PlaybackCacheError.rangeUnsupported {
            // Expected: the engine can now reopen through native HTTP.
        }
        #expect(PlaybackCacheURLProtocol.rangeHeaders == ["bytes=0-15"])
    }

    @Test func ignoredRangeResponseCannotTriggerQuadraticPrefixDownloads() throws {
        PlaybackCacheURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackCacheURLProtocol.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)

        do {
            _ = try loader.load(
                url: URL(string: "https://cache.test/video.mkv")!,
                range: PlaybackByteRange(32, 48),
                priority: URLSessionTask.highPriority
            )
            Issue.record("A later whole-body response was accepted as range data")
        } catch PlaybackCacheError.rangeUnsupported {
            // Expected: no prefix is downloaded or discarded.
        }
        #expect(PlaybackCacheURLProtocol.rangeHeaders == ["bytes=32-47"])
    }

    @Test func hlsCacheSkipsMutablePlaylistsAndUnsupportedSchemes() {
        #expect(!HLSPlaybackCacheScope.shouldCache(
            url: URL(string: "https://media.test/master.m3u8?token=one")!
        ))
        #expect(HLSPlaybackCacheScope.shouldCache(
            url: URL(string: "https://media.test/hls/main/001.ts?token=one")!
        ))
        #expect(!HLSPlaybackCacheScope.shouldCache(
            url: URL(string: "file:///tmp/001.ts")!
        ))
    }

    @Test func hlsManifestReferencesResolveRelativeResources() {
        let manifest = Data("""
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="keys/one.bin"
        #EXTINF:6.0,
        segment-001.m4s
        """.utf8)
        let base = URL(string: "https://media.test/hls/main/index.m3u8?token=one")!

        let references = HLSPlaybackCacheScope.playlistReferences(
            data: manifest,
            relativeTo: base
        )

        #expect(references.map(\.absoluteString) == [
            "https://media.test/hls/main/init.mp4",
            "https://media.test/hls/main/keys/one.bin",
            "https://media.test/hls/main/segment-001.m4s"
        ])
    }

    @Test func hlsVariantSelectionDoesNotMistakeAlternateAudioForVideo() {
        let manifest = Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio/main.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO="audio"
        video/main.m3u8
        """.utf8)
        let base = URL(string: "https://media.test/master.m3u8")!

        let variants = HLSPlaybackCacheScope.variantPlaylistURLs(
            data: manifest,
            relativeTo: base
        )

        #expect(variants.map(\.absoluteString) == ["https://media.test/video/main.m3u8"])
    }

    @Test func hlsCacheEvictsInactiveLRUWithinSharedByteBudget() throws {
        let payload = Data(repeating: 0xCD, count: 256)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try HLSPlaybackCacheScope(
            itemID: "episode-hls",
            sourceURL: URL(string: "https://media.test/master.m3u8")!,
            directory: directory,
            byteLimit: 64,
            maxResources: 3,
            requestSize: 32,
            resourceLoader: PlaybackCacheLoaderStub(payload: payload)
        )
        defer { cache.cancelAndRemove() }
        let firstURL = URL(string: "https://media.test/one.ts")!
        let secondURL = URL(string: "https://media.test/two.ts")!
        let thirdURL = URL(string: "https://media.test/three.ts")!

        let firstLease = try cache.leaseResource(at: firstURL)
        let first = try #require(firstLease)
        #expect(try first.scope.read(offset: 0, length: 8).count == 8)
        first.close()
        let secondLease = try cache.leaseResource(at: secondURL)
        let second = try #require(secondLease)
        #expect(try second.scope.read(offset: 0, length: 8).count == 8)
        second.close()
        let thirdLease = try cache.leaseResource(at: thirdURL)
        let third = try #require(thirdLease)
        #expect(try third.scope.read(offset: 0, length: 8).count == 8)
        third.close()

        #expect(cache.metrics.cachedBytes == 64)
        #expect(cache.metrics.networkBytes == 96)
        #expect(cache.metrics.requestCount == 3)
        #expect(cache.metrics.evictionCount == 1)
        #expect(cache.metrics.resourceCount == 2)
        #expect(cache.cachedResourceURLs == [secondURL, thirdURL])
    }

    @Test func hlsCacheNeverEvictsAnActivelyLeasedResource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try HLSPlaybackCacheScope(
            itemID: "active-hls",
            sourceURL: URL(string: "https://media.test/master.m3u8")!,
            directory: directory,
            byteLimit: 64,
            maxResources: 1,
            requestSize: 32
        )
        defer { cache.cancelAndRemove() }
        let activeURL = URL(string: "https://media.test/active.ts")!
        let blockedURL = URL(string: "https://media.test/blocked.ts")!

        let activeLease = try cache.leaseResource(at: activeURL)
        let active = try #require(activeLease)
        #expect(try cache.leaseResource(at: blockedURL) == nil)
        #expect(cache.cachedResourceURLs == [activeURL])
        active.close()
    }

    @Test func hlsCacheReopensSuspendedFilesWithoutLosingHits() throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try HLSPlaybackCacheScope(
            itemID: "resume-hls",
            sourceURL: URL(string: "https://media.test/master.m3u8")!,
            directory: directory,
            byteLimit: 128,
            maxResources: 2,
            requestSize: 64,
            resourceLoader: loader
        )
        defer { cache.cancelAndRemove() }
        let segmentURL = URL(string: "https://media.test/segment.ts")!

        let firstLease = try cache.leaseResource(at: segmentURL)
        let first = try #require(firstLease)
        #expect(try first.scope.read(offset: 16, length: 8).count == 8)
        first.close()

        let resumedLease = try cache.leaseResource(at: segmentURL)
        let resumed = try #require(resumedLease)
        #expect(try resumed.scope.read(offset: 16, length: 8).count == 8)
        resumed.close()

        #expect(loader.requestCount == 1)
        #expect(cache.metrics.cacheHitBytes == 8)
    }

    @MainActor
    @Test func coordinatorPromotesOnlyThePreparedSuccessor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(
            rootDirectory: root,
            isEnabled: true,
            allowsTranscodeCaching: true
        )
        let current = coordinator.activate(
            itemID: "episode-1",
            url: URL(string: "https://media.test/one.mkv")!,
            method: .directPlay,
            expectedLength: 1_024
        )
        let prepared = coordinator.stageNext(
            itemID: "episode-2",
            url: URL(string: "https://media.test/two.mkv")!,
            method: .directPlay,
            expectedLength: 1_024
        )

        #expect(current != nil)
        #expect(prepared != nil)
        #expect(coordinator.current === current)
        #expect(coordinator.next === prepared)

        let promoted = coordinator.activate(
            itemID: "episode-2",
            url: URL(string: "https://media.test/two.mkv")!,
            method: .directPlay,
            expectedLength: 1_024
        )

        #expect(promoted === prepared)
        #expect(coordinator.current === prepared)
        #expect(coordinator.next == nil)
        coordinator.discardAll()
    }

    @MainActor
    @Test func coordinatorCreatesAndPromotesTranscodeResourceCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(
            rootDirectory: root,
            isEnabled: true,
            allowsTranscodeCaching: true
        )
        let hlsURL = URL(string: "https://media.test/Videos/id/master.m3u8?token=one")!

        let staged = coordinator.stageNext(
            itemID: "episode-hls",
            url: hlsURL,
            method: .transcode,
            expectedLength: nil
        )
        #expect(staged?.hlsScope != nil)
        #expect(staged?.directScope == nil)

        let promoted = coordinator.activate(
            itemID: "episode-hls",
            url: hlsURL,
            method: .transcode,
            expectedLength: nil
        )
        #expect(promoted === staged)
        #expect(coordinator.current === staged)
        #expect(coordinator.next == nil)
        coordinator.discardAll()
    }

    @MainActor
    @Test func coordinatorCannotCacheTranscodeWhenReleasePolicyDisallowsIt() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(
            rootDirectory: root,
            isEnabled: true,
            allowsTranscodeCaching: false
        )

        #expect(coordinator.activate(
            itemID: "episode-hls",
            url: URL(string: "https://media.test/Videos/id/master.m3u8")!,
            method: .transcode,
            expectedLength: nil
        ) == nil)
        #expect(coordinator.current == nil)

        // Release's HLS boundary must not disable the direct-file buffer.
        #expect(coordinator.activate(
            itemID: "movie-direct",
            url: URL(string: "https://media.test/movie.mkv")!,
            method: .directPlay,
            expectedLength: 1_024
        )?.directScope != nil)
        coordinator.discardAll()
    }

    @MainActor
    @Test func disabledCoordinatorCannotReplaceNativePlaybackTransport() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(rootDirectory: root, isEnabled: false)
        let url = URL(string: "https://media.test/movie.mkv")!

        #expect(coordinator.activate(
            itemID: "movie",
            url: url,
            method: .directPlay,
            expectedLength: 1_024
        ) == nil)
        #expect(coordinator.stageNext(
            itemID: "next",
            url: url,
            method: .transcode,
            expectedLength: nil
        ) == nil)
        #expect(coordinator.current == nil)
        #expect(coordinator.next == nil)
    }
}

private nonisolated final class PlaybackCacheURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedRanges: [String] = []

    static var rangeHeaders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRanges
    }

    static func reset() {
        lock.lock()
        recordedRanges = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cache.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRanges.append(request.value(forHTTPHeaderField: "Range") ?? "")
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "256"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((0..<256).map(UInt8.init)))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private nonisolated final class PlaybackCacheLoaderStub: PlaybackRangeLoading, @unchecked Sendable {
    private let payload: Data
    private let lock = NSLock()
    private var requests = 0
    private var ranges: [PlaybackByteRange] = []
    private var cancelled = false

    init(payload: Data) {
        self.payload = payload
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var requestedRanges: [PlaybackByteRange] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw PlaybackCacheError.cancelled }
        requests += 1
        ranges.append(range)
        let lower = min(Int(range.lowerBound), payload.count)
        let upper = min(Int(range.upperBound), payload.count)
        return PlaybackRangeResponse(
            data: payload.subdata(in: lower..<upper),
            offset: Int64(lower),
            totalLength: Int64(payload.count)
        )
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
