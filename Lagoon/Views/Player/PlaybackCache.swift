import Foundation

/// A half-open byte interval stored in a playback cache file.
nonisolated struct PlaybackByteRange: Equatable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64

    init(_ lowerBound: Int64, _ upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = max(upperBound, lowerBound)
    }

    var count: Int64 { upperBound - lowerBound }

    func contains(_ other: PlaybackByteRange) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }
}

/// Sorted, coalesced ranges. Keeping this logic independent from file and
/// network I/O makes cache accounting and cap enforcement deterministic.
nonisolated struct PlaybackByteRangeSet: Equatable, Sendable {
    private(set) var ranges: [PlaybackByteRange] = []

    var byteCount: Int64 { ranges.reduce(0) { $0 + $1.count } }

    func contains(_ range: PlaybackByteRange) -> Bool {
        ranges.contains { $0.contains(range) }
    }

    @discardableResult
    mutating func insert(_ range: PlaybackByteRange) -> Int64 {
        guard range.count > 0 else { return 0 }
        let before = byteCount
        var merged = range
        var output: [PlaybackByteRange] = []
        var didInsert = false

        for existing in ranges {
            if existing.upperBound < merged.lowerBound {
                output.append(existing)
            } else if merged.upperBound < existing.lowerBound {
                if !didInsert {
                    output.append(merged)
                    didInsert = true
                }
                output.append(existing)
            } else {
                merged = PlaybackByteRange(
                    min(merged.lowerBound, existing.lowerBound),
                    max(merged.upperBound, existing.upperBound)
                )
            }
        }
        if !didInsert { output.append(merged) }
        ranges = output
        return byteCount - before
    }
}

nonisolated struct PlaybackCacheMetrics: Equatable, Sendable {
    let cachedBytes: Int64
    let networkBytes: Int64
    let cacheHitBytes: Int64
    let requestCount: Int
    let networkRequestSeconds: Double

    var hitRate: Double {
        let total = cacheHitBytes + networkBytes
        return total > 0 ? Double(cacheHitBytes) / Double(total) : 0
    }

    var averageRequestMilliseconds: Double {
        requestCount > 0 ? networkRequestSeconds * 1_000 / Double(requestCount) : 0
    }
}

nonisolated struct PlaybackRangeResponse: Sendable {
    let data: Data
    let offset: Int64
    let totalLength: Int64?
}

nonisolated protocol PlaybackRangeLoading: AnyObject, Sendable {
    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse
    func cancelAll()
}

nonisolated enum PlaybackCacheError: LocalizedError {
    case cancelled
    case invalidResponse
    case rangeUnsupported
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: "Playback caching was cancelled."
        case .invalidResponse: "The media server returned an invalid byte-range response."
        case .rangeUnsupported: "The media server does not support the requested byte range."
        case .storageUnavailable: "The playback cache could not be opened."
        }
    }
}

/// A bounded streaming range request. The delegate stops after the requested
/// bytes even when a server incorrectly ignores Range and answers with 200,
/// so a malformed response can never materialize a whole movie in memory.
nonisolated private final class PlaybackRangeRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let requestedRange: PlaybackByteRange
    private let sessionConfiguration: URLSessionConfiguration
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var received = Data()
    private var result: Result<PlaybackRangeResponse, Error>?
    private let taskPriority: Float

    init(
        url: URL,
        range: PlaybackByteRange,
        priority: Float,
        sessionConfiguration: URLSessionConfiguration
    ) {
        requestedRange = range
        taskPriority = priority
        self.sessionConfiguration = sessionConfiguration
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue(
            "bytes=\(range.lowerBound)-\(max(range.upperBound - 1, range.lowerBound))",
            forHTTPHeaderField: "Range"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if priority <= URLSessionTask.lowPriority {
            // Proactive fill must never consume metered/Low Data Mode paths.
            // Foreground playback remains allowed and wins independently.
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        self.request = request
        super.init()
    }

    func run() throws -> PlaybackRangeResponse {
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        lock.lock()
        if let result {
            lock.unlock()
            session.invalidateAndCancel()
            return try result.get()
        }
        self.session = session
        self.task = task
        lock.unlock()
        task.priority = taskPriority
        task.resume()
        completion.wait()
        lock.lock()
        let result = result ?? .failure(PlaybackCacheError.cancelled)
        self.session = nil
        self.task = nil
        lock.unlock()
        session.invalidateAndCancel()
        return try result.get()
    }

    func cancel() {
        finish(.failure(PlaybackCacheError.cancelled), cancelTask: true)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(PlaybackCacheError.invalidResponse), cancelTask: true)
            return
        }
        let validPartial = http.statusCode == 206
            && Self.responseOffset(response: http) == requestedRange.lowerBound
        let validWhole = http.statusCode == 200 && requestedRange.lowerBound == 0
        guard validPartial || validWhole else {
            completionHandler(.cancel)
            finish(.failure(PlaybackCacheError.rangeUnsupported), cancelTask: true)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        let remaining = max(Int(requestedRange.count) - received.count, 0)
        if remaining > 0 {
            received.append(data.prefix(remaining))
        }
        let complete = received.count >= Int(requestedRange.count)
        lock.unlock()
        if complete {
            finishCurrentResponse(cancelTask: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let hasBytes = !received.isEmpty
        lock.unlock()
        if hasBytes {
            finishCurrentResponse(cancelTask: false)
        } else {
            finish(.failure(error ?? PlaybackCacheError.invalidResponse), cancelTask: false)
        }
    }

    private func finishCurrentResponse(cancelTask: Bool) {
        lock.lock()
        guard result == nil, let response else {
            lock.unlock()
            return
        }
        let data = received
        let totalLength = Self.totalLength(response: response, requestedRange: requestedRange)
        lock.unlock()
        finish(.success(PlaybackRangeResponse(
            data: data,
            offset: Self.responseOffset(response: response) ?? 0,
            totalLength: totalLength
        )), cancelTask: cancelTask)
    }

    private func finish(_ newResult: Result<PlaybackRangeResponse, Error>, cancelTask: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let task = self.task
        lock.unlock()
        if cancelTask { task?.cancel() }
        completion.signal()
    }

    private static func totalLength(
        response: HTTPURLResponse,
        requestedRange: PlaybackByteRange
    ) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last,
           total != "*",
           let value = Int64(total) {
            return value
        }
        if response.statusCode == 200, response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return nil
    }

    private static func responseOffset(response: HTTPURLResponse) -> Int64? {
        guard response.statusCode == 206,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
            return response.statusCode == 200 ? 0 : nil
        }
        let components = contentRange.split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              components[0].lowercased() == "bytes",
              let bounds = components[1].split(separator: "/", maxSplits: 1).first,
              let lower = bounds.split(separator: "-", maxSplits: 1).first else { return nil }
        return Int64(lower)
    }
}

nonisolated final class URLSessionPlaybackRangeLoader: PlaybackRangeLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var active: [ObjectIdentifier: PlaybackRangeRequest] = [:]
    private var cancelled = false

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        var lastError: Error = PlaybackCacheError.invalidResponse
        for attempt in 0..<3 {
            let request = PlaybackRangeRequest(
                url: url,
                range: range,
                priority: priority,
                sessionConfiguration: configuration
            )
            let identifier = ObjectIdentifier(request)
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                throw PlaybackCacheError.cancelled
            }
            active[identifier] = request
            lock.unlock()
            do {
                let response = try request.run()
                removeActive(identifier)
                return response
            } catch PlaybackCacheError.cancelled {
                removeActive(identifier)
                throw PlaybackCacheError.cancelled
            } catch {
                removeActive(identifier)
                lastError = error
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
                }
            }
        }
        throw lastError
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let requests = Array(active.values)
        lock.unlock()
        requests.forEach { $0.cancel() }
    }

    private func removeActive(_ identifier: ObjectIdentifier) {
        lock.lock()
        active.removeValue(forKey: identifier)
        lock.unlock()
    }
}

/// One item's sparse, discardable cache file. Reads happen on FFmpeg's demux
/// queue. File/range bookkeeping is serialized, while low-priority prefetch
/// and a foreground seek may fetch independently when foreground must win.
nonisolated final class PlaybackCacheScope: @unchecked Sendable {
    let itemID: String
    let sourceURL: URL
    let fileURL: URL

    private let byteLimit: Int64
    private let requestSize: Int64
    private let loader: PlaybackRangeLoading
    private let lock = NSCondition()
    private let cancellationLock = NSLock()
    private var file: FileHandle?
    private var cached = PlaybackByteRangeSet()
    private var knownLength: Int64?
    private var networkBytes: Int64 = 0
    private var cacheHitBytes: Int64 = 0
    private var requestCount = 0
    private var networkRequestSeconds: Double = 0
    private var cancelled = false
    private var storageDisabled = false
    private var inFlight: [UUID: (range: PlaybackByteRange, priority: Float)] = [:]

    init(
        itemID: String,
        sourceURL: URL,
        expectedLength: Int64?,
        directory: URL,
        byteLimit: Int64 = 512 * 1_024 * 1_024,
        requestSize: Int64 = 8 * 1_024 * 1_024,
        loader: PlaybackRangeLoading = URLSessionPlaybackRangeLoader()
    ) throws {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.knownLength = expectedLength.flatMap { $0 > 0 ? $0 : nil }
        self.byteLimit = max(byteLimit, 0)
        self.requestSize = max(requestSize, 1)
        self.loader = loader
        fileURL = directory.appendingPathComponent("ranges.cache", isDirectory: false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let file = try? FileHandle(forUpdating: fileURL) else {
            throw PlaybackCacheError.storageUnavailable
        }
        self.file = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    deinit {
        file?.closeFile()
    }

    var contentLength: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return knownLength
    }

    var prefetchByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return min(knownLength ?? byteLimit, byteLimit)
    }

    var metrics: PlaybackCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        return PlaybackCacheMetrics(
            cachedBytes: cached.byteCount,
            networkBytes: networkBytes,
            cacheHitBytes: cacheHitBytes,
            requestCount: requestCount,
            networkRequestSeconds: networkRequestSeconds
        )
    }

    func read(offset: Int64, length: Int, priority: Float = URLSessionTask.highPriority) throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        try checkCancellation()
        lock.lock()
        guard let file else {
            lock.unlock()
            throw PlaybackCacheError.cancelled
        }

        let requestedEnd = min(
            offset + Int64(length),
            knownLength ?? Int64.max
        )
        let requested = PlaybackByteRange(offset, requestedEnd)
        guard requested.count > 0 else {
            lock.unlock()
            return Data()
        }
        if cached.contains(requested) {
            do {
                try file.seek(toOffset: UInt64(requested.lowerBound))
                let data = try file.read(upToCount: Int(requested.count)) ?? Data()
                if data.count == Int(requested.count) {
                    cacheHitBytes += requested.count
                    lock.unlock()
                    return data
                }
            } catch {
                // A cache file is an optimization. Storage pressure or a
                // purged file must fall through to the network, never turn
                // a healthy stream into EOF.
            }
            storageDisabled = true
            cached = PlaybackByteRangeSet()
        }

        // Low-priority prefetch follows an overlapping foreground miss
        // instead of downloading the same chunk twice. A foreground seek
        // never waits behind low-priority prefetch; it starts its own request.
        if inFlight.values.contains(where: {
            $0.range.contains(requested) && $0.priority >= priority
        }) {
            _ = lock.wait(until: Date().addingTimeInterval(15))
            lock.unlock()
            return try read(offset: offset, length: length, priority: priority)
        }

        let fetchEnd = min(
            max(requested.upperBound, requested.lowerBound + requestSize),
            knownLength ?? Int64.max
        )
        let fetchRange = PlaybackByteRange(requested.lowerBound, fetchEnd)
        let fetchID = UUID()
        inFlight[fetchID] = (fetchRange, priority)
        requestCount += 1
        lock.unlock()
        let requestStarted = ProcessInfo.processInfo.systemUptime
        let response: PlaybackRangeResponse
        do {
            response = try loader.load(url: sourceURL, range: fetchRange, priority: priority)
            try checkCancellation()
        } catch {
            finishFetch(fetchID)
            throw error
        }

        lock.lock()
        inFlight.removeValue(forKey: fetchID)
        lock.broadcast()
        defer { lock.unlock() }
        networkRequestSeconds += max(ProcessInfo.processInfo.systemUptime - requestStarted, 0)
        if let total = response.totalLength, total > 0 { knownLength = total }
        networkBytes += Int64(response.data.count)

        let remainingCapacity = storageDisabled ? 0 : max(byteLimit - cached.byteCount, 0)
        let storableCount = min(Int64(response.data.count), remainingCapacity)
        if storableCount > 0 {
            let storable = response.data.prefix(Int(storableCount))
            do {
                try file.seek(toOffset: UInt64(response.offset))
                try file.write(contentsOf: storable)
                cached.insert(PlaybackByteRange(response.offset, response.offset + storableCount))
            } catch {
                storageDisabled = true
                cached = PlaybackByteRangeSet()
            }
        }
        let relativeOffset = max(requested.lowerBound - response.offset, 0)
        guard relativeOffset < response.data.count else { return Data() }
        let available = min(Int64(response.data.count) - relativeOffset, requested.count)
        return response.data.subdata(in: Int(relativeOffset)..<Int(relativeOffset + available))
    }

    func prefetch(byteCount: Int64) async {
        guard byteCount > 0 else { return }
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var offset: Int64 = 0
            while offset < byteCount, !Task.isCancelled {
                let count = Int(min(self.requestSize, byteCount - offset))
                guard let data = try? self.read(
                    offset: offset,
                    length: count,
                    priority: URLSessionTask.lowPriority
                ), !data.isEmpty else { return }
                offset += Int64(data.count)
            }
        }.value
    }

    func cancelAndRemove() {
        cancellationLock.lock()
        guard !cancelled else {
            cancellationLock.unlock()
            return
        }
        cancelled = true
        cancellationLock.unlock()
        loader.cancelAll()
        lock.lock()
        lock.broadcast()
        lock.unlock()
        // A range request may still be unwinding on the demux queue. File
        // closure and deletion wait there, never on the main actor that is
        // animating player dismissal or an episode handoff.
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            file?.closeFile()
            file = nil
            let directory = fileURL.deletingLastPathComponent()
            lock.unlock()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        let isCancelled = cancelled
        cancellationLock.unlock()
        if isCancelled { throw PlaybackCacheError.cancelled }
    }

    private func finishFetch(_ identifier: UUID) {
        lock.lock()
        inFlight.removeValue(forKey: identifier)
        lock.broadcast()
        lock.unlock()
    }
}

/// Main-actor ownership of the only two cache scopes Lagoon permits: the
/// active item and its staged successor.
@MainActor
final class PlaybackCacheCoordinator {
    private let rootDirectory: URL
    private(set) var current: PlaybackCacheScope?
    private(set) var next: PlaybackCacheScope?
    private var currentPrefetchTask: Task<Void, Never>?

    init(rootDirectory: URL? = nil) {
        let caches = rootDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.rootDirectory = caches
            .appendingPathComponent("Lagoon", isDirectory: true)
            .appendingPathComponent("Playback", isDirectory: true)
        removeStaleScopes()
    }

    func activate(
        itemID: String,
        url: URL,
        method: PlayMethod,
        expectedLength: Int64?
    ) -> PlaybackCacheScope? {
        if let next, next.itemID == itemID, next.sourceURL == url {
            currentPrefetchTask?.cancel()
            current?.cancelAndRemove()
            current = next
            self.next = nil
            return next
        }
        currentPrefetchTask?.cancel()
        current?.cancelAndRemove()
        current = makeScope(itemID: itemID, url: url, method: method, expectedLength: expectedLength)
        return current
    }

    func prefetchCurrent() {
        currentPrefetchTask?.cancel()
        guard let current else { return }
        currentPrefetchTask = Task {
            await current.prefetch(byteCount: current.prefetchByteCount)
        }
    }

    func stageNext(
        itemID: String,
        url: URL,
        method: PlayMethod,
        expectedLength: Int64?
    ) -> PlaybackCacheScope? {
        if next?.itemID == itemID, next?.sourceURL == url { return next }
        next?.cancelAndRemove()
        next = makeScope(itemID: itemID, url: url, method: method, expectedLength: expectedLength)
        return next
    }

    func discardNext(itemID: String? = nil) {
        guard itemID == nil || next?.itemID == itemID else { return }
        next?.cancelAndRemove()
        next = nil
    }

    func discardCurrent(preservingNext: Bool) {
        currentPrefetchTask?.cancel()
        currentPrefetchTask = nil
        current?.cancelAndRemove()
        current = nil
        if !preservingNext {
            discardNext()
        }
    }

    func discardAll() {
        discardCurrent(preservingNext: false)
    }

    private func makeScope(
        itemID: String,
        url: URL,
        method: PlayMethod,
        expectedLength: Int64?
    ) -> PlaybackCacheScope? {
        // HLS opens child playlists and segments outside the top-level AVIO
        // context. It gets its own io_open cache path in a later HEL-86 slice.
        guard method == .directPlay || method == .directStream else { return nil }
        let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try? PlaybackCacheScope(
            itemID: itemID,
            sourceURL: url,
            expectedLength: expectedLength,
            directory: directory
        )
    }

    private func removeStaleScopes() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let children = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for child in children ?? [] {
            let values = try? child.resourceValues(forKeys: keys)
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
