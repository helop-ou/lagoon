import Foundation
import Testing
@testable import Lagoon

@Suite("Playback cache", .serialized)
struct PlaybackCacheTests {
    @Test func rangesMergeOverlapAndAdjacencyWithoutDoubleCounting() {
        var ranges = PlaybackByteRangeSet()
        #expect(ranges.insert(PlaybackByteRange(10, 20)) == 10)
        #expect(ranges.insert(PlaybackByteRange(20, 30)) == 10)
        #expect(ranges.insert(PlaybackByteRange(15, 25)) == 0)
        #expect(ranges.ranges == [PlaybackByteRange(10, 30)])
        #expect(ranges.byteCount == 20)
        #expect(ranges.contains(PlaybackByteRange(12, 28)))
        #expect(!ranges.contains(PlaybackByteRange(0, 12)))
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

    @Test func ignoredRangeResponseIsCappedWithoutBufferingTheWholeBody() throws {
        PlaybackCacheURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackCacheURLProtocol.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)

        let response = try loader.load(
            url: URL(string: "https://cache.test/video.mkv")!,
            range: PlaybackByteRange(0, 16),
            priority: URLSessionTask.highPriority
        )

        #expect(response.data.count == 16)
        #expect(response.totalLength == 256)
        #expect(PlaybackCacheURLProtocol.rangeHeaders == ["bytes=0-15"])
    }

    @MainActor
    @Test func coordinatorPromotesOnlyThePreparedSuccessor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(rootDirectory: root)
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
    private var cancelled = false

    init(payload: Data) {
        self.payload = payload
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
