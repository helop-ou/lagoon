import Foundation
import os
import Testing
@testable import Lagoon

/// Intercepts the transport's URLSession; no network.
final class SentryMockURLProtocol: URLProtocol {
    private nonisolated struct State: Sendable {
        var responder: @Sendable (URLRequest) -> (status: Int, headers: [String: String]) = { _ in (200, [:]) }
        var recorded: [URLRequest] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var responder: @Sendable (URLRequest) -> (status: Int, headers: [String: String]) {
        get { state.withLock { $0.responder } }
        set { state.withLock { $0.responder = newValue } }
    }

    static var requests: [URLRequest] { state.withLock { $0.recorded } }

    static func reset() {
        state.withLock { $0 = State() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responder = Self.state.withLock { state in
            state.recorded.append(request)
            return state.responder
        }
        let answer = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Sentry transport", .serialized)
struct SentryTransportTests {
    static let context = DiagnosticContext(
        bundleIdentifier: "ee.helop.lagoon", appVersion: "0.1", build: "95", osName: "tvOS", osVersion: "26.0",
        deviceModel: "AppleTV14,1", isSimulator: true, environment: "debug", engineVersion: "lavf62.3.100"
    )

    static func incident(_ code: DiagnosticIncidentCode = .playbackStall) -> DiagnosticIncident {
        DiagnosticIncident(
            code: code, level: .warning, variant: ["test"], fields: ["stalls": .int(1)],
            history: [], occurrences: 1, timestamp: Date(), uptime: 10
        )
    }

    static func makeTransport(enabled: @escaping @Sendable () -> Bool = { true }) throws -> (SentryTransport, URL) {
        SentryMockURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sentry-transport-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SentryMockURLProtocol.self]
        let transport = SentryTransport(
            dsn: try #require(SentryDSN(string: "https://key@o1.ingest.de.sentry.io/1")),
            context: context,
            directory: directory,
            session: URLSession(configuration: configuration),
            isEnabled: enabled
        )
        return (transport, directory)
    }

    static func pendingCount(_ directory: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".envelope") }.count
    }

    static func wait(until condition: @escaping () -> Bool, seconds: Double = 3) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func anAcceptedEnvelopeLeavesTheQueue() async throws {
        let (transport, directory) = try Self.makeTransport()
        transport.submit(Self.incident())
        await Self.wait { SentryMockURLProtocol.requests.count == 1 && Self.pendingCount(directory) == 0 }
        let request = try #require(SentryMockURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://o1.ingest.de.sentry.io/api/1/envelope/")
        #expect(request.value(forHTTPHeaderField: "X-Sentry-Auth")?.contains("sentry_key=key") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-sentry-envelope")
        #expect(Self.pendingCount(directory) == 0)
    }

    @Test func turningReportingOffStopsUploadsAndDiscardsTheQueue() async throws {
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let (transport, directory) = try Self.makeTransport(enabled: { enabled.withLock { $0 } })
        // Park one envelope by answering with a server error.
        SentryMockURLProtocol.responder = { _ in (503, [:]) }
        transport.submit(Self.incident())
        await Self.wait { SentryMockURLProtocol.requests.count == 1 }
        #expect(Self.pendingCount(directory) == 1)
        // Opt out: a flush neither sends nor keeps it, and nothing new queues.
        enabled.withLock { $0 = false }
        SentryMockURLProtocol.responder = { _ in (200, [:]) }
        transport.flush()
        await Self.wait { Self.pendingCount(directory) == 0 }
        transport.submit(Self.incident(.playbackFailed))
        try await Task.sleep(for: .milliseconds(300))
        #expect(SentryMockURLProtocol.requests.count == 1)
        #expect(Self.pendingCount(directory) == 0)
    }

    @Test func aRateLimitOnASuccessPausesTheNextUpload() async throws {
        let (transport, directory) = try Self.makeTransport()
        SentryMockURLProtocol.responder = { _ in (200, ["X-Sentry-Rate-Limits": "60:error:organization"]) }
        transport.submit(Self.incident())
        transport.submit(Self.incident(.playbackFailed))
        await Self.wait { SentryMockURLProtocol.requests.count == 1 && Self.pendingCount(directory) == 1 }
        try await Task.sleep(for: .milliseconds(500))
        // The first was taken; the second waits out the 60 s the server asked for.
        #expect(SentryMockURLProtocol.requests.count == 1)
        #expect(Self.pendingCount(directory) == 1)
        transport.flush()
        try await Task.sleep(for: .milliseconds(300))
        #expect(SentryMockURLProtocol.requests.count == 1)
    }

    @Test func aRejectedEnvelopeIsDroppedAndTheNextOneSent() async throws {
        let (transport, directory) = try Self.makeTransport()
        SentryMockURLProtocol.responder = { _ in (400, [:]) }
        transport.submit(Self.incident())
        await Self.wait { SentryMockURLProtocol.requests.count == 1 && Self.pendingCount(directory) == 0 }
        SentryMockURLProtocol.responder = { _ in (200, [:]) }
        transport.submit(Self.incident(.playbackFailed))
        await Self.wait { SentryMockURLProtocol.requests.count == 2 }
        #expect(SentryMockURLProtocol.requests.count == 2)
        #expect(Self.pendingCount(directory) == 0)
    }
}
