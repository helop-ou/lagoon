import Foundation
import OSLog
import Synchronization
import Testing
@testable import Lagoon

@Suite("Playback reporting session", .serialized)
@MainActor
struct PlaybackReportingSessionTests {
    @Test func stopIsClaimedOnceAndCapturesTheFinalPosition() async throws {
        let client = makeClient(holding: ["/Sessions/Playing/Stopped"])
        defer { ReportingURLProtocol.release("/Sessions/Playing/Stopped") }
        let reporter = makeReporter(client: client)
        #expect(client.playbackReports.hasOpenSessions)
        try await reporter.reportStart(at: 12.5)

        let stop = try #require(reporter.stop(at: 42.75))
        #expect(!reporter.isActive)
        #expect(reporter.stop(at: 99) == nil)
        try await waitUntil { ReportingURLProtocol.isHolding("/Sessions/Playing/Stopped") }
        #expect(client.playbackReports.hasOpenSessions)

        let requests = ReportingURLProtocol.requests
        #expect(requests.map(\.path) == ["/Sessions/Playing", "/Sessions/Playing/Stopped"])
        #expect(requests.allSatisfy { $0.method == "POST" })
        let start = try payload(try #require(requests.first))
        #expect(start["PositionTicks"] as? Int64 == Ticks.ticks(12.5))
        #expect(start["PlayMethod"] as? String == "DirectPlay")
        #expect(start["CanSeek"] as? Bool == true)
        let stopped = try payload(try #require(requests.last))
        #expect(stopped["ItemId"] as? String == "item")
        #expect(stopped["MediaSourceId"] as? String == "source")
        #expect(stopped["PlaySessionId"] as? String == "session")
        #expect(stopped["PositionTicks"] as? Int64 == Ticks.ticks(42.75))

        ReportingURLProtocol.release("/Sessions/Playing/Stopped")
        await stop.value
        #expect(!client.playbackReports.hasOpenSessions)
        #expect(reporter.stop(at: 100) == nil)
        #expect(ReportingURLProtocol.requests.count == 2)
    }

    @Test func failedStopStillClosesTheLedger() async throws {
        let client = makeClient(stopStatus: 503)
        let reporter = makeReporter(client: client)
        let stop = try #require(reporter.stop(at: 28))
        await stop.value
        #expect(!client.playbackReports.hasOpenSessions)
        #expect(!reporter.isActive)
        #expect(reporter.stop(at: 29) == nil)
        #expect(ReportingURLProtocol.requests.map(\.path) == ["/Sessions/Playing/Stopped"])
    }

    @Test func suspendedStopDoesNotRetainTheReporter() async throws {
        let client = makeClient(holding: ["/Sessions/Playing/Stopped"])
        defer { ReportingURLProtocol.release("/Sessions/Playing/Stopped") }
        var reporter: PlaybackReportingSession? = makeReporter(client: client)
        weak let retainedReporter = reporter
        let stop = try #require(reporter?.stop(at: 37))
        reporter = nil
        #expect(retainedReporter == nil)

        try await waitUntil { ReportingURLProtocol.isHolding("/Sessions/Playing/Stopped") }
        #expect(retainedReporter == nil)
        #expect(client.playbackReports.hasOpenSessions)
        ReportingURLProtocol.release("/Sessions/Playing/Stopped")
        await stop.value
        #expect(!client.playbackReports.hasOpenSessions)
    }

    @Test func stoppingCancelsProgressAndReleasesItsCallbacks() async throws {
        let client = makeClient()
        let clock = ProgressClock()
        let reporter = makeReporter(client: client, clock: clock)
        let calls = ProgressCalls()
        let lifetime = installProgress(on: reporter, calls: calls)
        try await waitUntil { clock.isSleeping }
        let stop = try #require(reporter.stop(at: 18))
        // Cancellation reaches the wait before stop returns.
        #expect(clock.cancellations == 1)
        await stop.value
        // Callback release proves the loop exited.
        try await waitUntil { lifetime.value == nil }
        #expect(calls.snapshots == 0)
        #expect(calls.reports == 0)
        #expect(ReportingURLProtocol.requests.map(\.path) == ["/Sessions/Playing/Stopped"])
    }

    @Test func eachIntervalReportsTheSnapshotOnce() async throws {
        let client = makeClient()
        let clock = ProgressClock()
        let reporter = makeReporter(client: client, clock: clock)
        let calls = ProgressCalls()
        reporter.startProgress(snapshot: {
            calls.snapshots += 1
            return .init(seconds: 64.5, isPaused: true)
        }, didReport: {
            calls.reports += 1
        })
        try await waitUntil { clock.isSleeping }
        #expect(clock.requested == [PlaybackReportingSession.progressInterval])
        #expect(ReportingURLProtocol.requests.isEmpty)

        clock.advance()
        try await waitUntil { calls.reports == 1 && clock.isSleeping }
        #expect(calls.snapshots == 1)
        #expect(clock.requested.count == 2)
        let requests = ReportingURLProtocol.requests
        #expect(requests.map(\.path) == ["/Sessions/Playing/Progress"])
        let progress = try payload(try #require(requests.first))
        #expect(progress["ItemId"] as? String == "item")
        #expect(progress["MediaSourceId"] as? String == "source")
        #expect(progress["PlaySessionId"] as? String == "session")
        #expect(progress["PositionTicks"] as? Int64 == Ticks.ticks(64.5))
        #expect(progress["IsPaused"] as? Bool == true)
        #expect(progress["PlayMethod"] as? String == "DirectPlay")

        let stop = try #require(reporter.stop(at: 65))
        await stop.value
    }

    @Test func stoppedSessionRejectsAnotherStartAndProgressLoop() async throws {
        let client = makeClient()
        let reporter = makeReporter(client: client)
        let stop = try #require(reporter.stop(at: 18))
        await stop.value
        await #expect(throws: CancellationError.self) {
            try await reporter.reportStart(at: 19)
        }
        let calls = ProgressCalls()
        let lifetime = installProgress(on: reporter, calls: calls)
        #expect(lifetime.value == nil)
        #expect(calls.snapshots == 0)
        #expect(calls.reports == 0)
        #expect(ReportingURLProtocol.requests.map(\.path) == ["/Sessions/Playing/Stopped"])
    }

    @Test func cancellingASuspendedStartCannotReviveProgress() async throws {
        let client = makeClient(holding: ["/Sessions/Playing"])
        defer { ReportingURLProtocol.release("/Sessions/Playing") }
        let clock = ProgressClock()
        let reporter = makeReporter(client: client, clock: clock)
        let calls = ProgressCalls()
        // Asks for progress whatever the start report said: the session
        // itself has to refuse once it is stopped.
        let startup = Task {
            try? await reporter.reportStart(at: 12)
            return installProgress(on: reporter, calls: calls)
        }
        try await waitUntil { ReportingURLProtocol.isHolding("/Sessions/Playing") }
        startup.cancel()
        let stop = try #require(reporter.stop(at: 13))
        let lifetime = await startup.value
        await stop.value
        try await waitUntil { !ReportingURLProtocol.isHolding("/Sessions/Playing") }
        #expect(lifetime.value == nil)
        #expect(clock.requested.isEmpty)
        #expect(calls.snapshots == 0)
        #expect(calls.reports == 0)
        #expect(!client.playbackReports.hasOpenSessions)
        #expect(ReportingURLProtocol.requests.map(\.path) == ["/Sessions/Playing", "/Sessions/Playing/Stopped"])
    }

    @Test func alreadyCancelledStartDoesNotReachTheServer() async throws {
        let client = makeClient()
        let reporter = makeReporter(client: client)
        let start = Task { try await reporter.reportStart(at: 12) }
        // Both operations run on the main actor, so cancellation happens
        // before the task can enter the reporter.
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(ReportingURLProtocol.requests.isEmpty)
        let stop = try #require(reporter.stop(at: 12))
        await stop.value
        #expect(!client.playbackReports.hasOpenSessions)
    }

    private func makeClient(holding paths: Set<String> = [], stopStatus: Int = 204) -> JellyfinClient {
        ReportingURLProtocol.reset(holding: paths, stopStatus: stopStatus)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportingURLProtocol.self]
        let client = JellyfinClient(deviceId: "reporting-tests", sessionConfiguration: configuration)
        client.configure(serverURL: URL(string: "https://playback-reporting.test")!)
        client.activateSession(token: "synthetic-token", userId: "viewer")
        return client
    }

    private func makeReporter(
        client: JellyfinClient,
        clock: ProgressClock = ProgressClock()
    ) -> PlaybackReportingSession {
        PlaybackReportingSession(
            client: client,
            itemID: "item",
            mediaSourceID: "source",
            playSessionID: "session",
            method: .directPlay,
            signpostID: .exclusive,
            progressSleep: { try await clock.sleep(for: $0) }
        )
    }

    private func payload(_ request: ReportingURLProtocol.Record) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func installProgress(on reporter: PlaybackReportingSession, calls: ProgressCalls) -> WeakProgressLifetime {
        let lifetime = ProgressLifetime()
        let weakLifetime = WeakProgressLifetime(lifetime)
        reporter.startProgress(snapshot: {
            calls.snapshots += 1
            return .init(seconds: lifetime.seconds, isPaused: false)
        }, didReport: {
            calls.reports += 1
        })
        return weakLifetime
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        try await Polling.untilMainActor(timeout: .seconds(15), pollInterval: .milliseconds(10), condition: condition)
        try #require(condition(), "The controlled reporting request did not reach its expected state")
    }
}

@MainActor
private final class ProgressCalls {
    var snapshots = 0
    var reports = 0
}

@MainActor
private final class ProgressLifetime {
    let seconds = 18.0
}

@MainActor
private final class WeakProgressLifetime {
    weak var value: ProgressLifetime?
    init(_ value: ProgressLifetime) { self.value = value }
}

/// Stands in for the wait between progress reports. A sleep ends only when
/// the test advances it, or by throwing when its task is cancelled.
private nonisolated final class ProgressClock: Sendable {
    private struct State {
        var requested: [Duration] = []
        var cancellations = 0
        var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())
    var requested: [Duration] { state.withLock { $0.requested } }
    var cancellations: Int { state.withLock { $0.cancellations } }
    var isSleeping: Bool { state.withLock { !$0.pending.isEmpty } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state in
            state.requested.append(duration)
            return state.requested.count
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state in
                    guard !state.cancelled.contains(id) else { return true }
                    state.pending[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.cancellations += 1
                state.cancelled.insert(id)
                return state.pending.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends every pending sleep, as the interval running out would.
    func advance() {
        let pending = state.withLock { state in
            let pending = state.pending
            state.pending.removeAll()
            return pending
        }
        for continuation in pending.values { continuation.resume() }
    }
}

/// URLProtocol callbacks may run off the main actor. All fixture state is
/// protected by the mutex; the subclass adds no unprotected instance state.
private nonisolated final class ReportingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Record: Sendable {
        let path: String
        let method: String?
        let body: Data
    }

    private struct State {
        var requests: [Record] = []
        var heldPaths: Set<String> = []
        var pending: [ReportingURLProtocol] = []
        var stopStatus = 204
    }

    private static let state = Mutex(State())
    static var requests: [Record] { state.withLock { $0.requests } }

    static func reset(holding paths: Set<String>, stopStatus: Int) {
        state.withLock { $0 = State(heldPaths: paths, stopStatus: stopStatus) }
    }

    static func isHolding(_ path: String) -> Bool {
        state.withLock { $0.pending.contains { $0.request.url?.path == path } }
    }

    static func release(_ path: String) {
        let pending = state.withLock { state in
            state.heldPaths.remove(path)
            let pending = state.pending.filter { $0.request.url?.path == path }
            state.pending.removeAll { $0.request.url?.path == path }
            return pending
        }
        for item in pending { item.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "playback-reporting.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Record(path: request.url?.path ?? "", method: request.httpMethod, body: requestBody())
        let held = Self.state.withLock { state in
            state.requests.append(record)
            guard state.heldPaths.contains(record.path) else { return false }
            state.pending.append(self)
            return true
        }
        if !held { respond() }
    }

    override func stopLoading() {
        Self.state.withLock { state in state.pending.removeAll { $0 === self } }
    }

    private func respond() {
        guard let url = request.url else { return }
        let status = Self.state.withLock { url.path == "/Sessions/Playing/Stopped" ? $0.stopStatus : 204 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func requestBody() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

/// A failure before the first frame must not report or restart from 0: the
/// engine reads 0 until it has presented its start.
@Suite("Playback reportable position")
struct PlaybackReportablePositionTests {
    @Test func theStartPointStandsUntilTheEngineHasStarted() {
        let seconds = PlaybackController.reportablePosition(
            engine: 0,
            engineHasStarted: false,
            lastKnown: 2865.7
        )
        #expect(seconds == 2865.7)
    }

    @Test func aStartedEngineIsTheTruth() {
        let seconds = PlaybackController.reportablePosition(
            engine: 2901.2,
            engineHasStarted: true,
            lastKnown: 2865.7
        )
        #expect(seconds == 2901.2)
    }

    @Test func noEngineKeepsTheLastKnownPosition() {
        let seconds = PlaybackController.reportablePosition(
            engine: nil,
            engineHasStarted: true,
            lastKnown: 2865.7
        )
        #expect(seconds == 2865.7)
    }
}
