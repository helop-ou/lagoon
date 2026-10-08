import Foundation
import Testing
@testable import Lagoon

/// Expected conditions go to the history only; an incident is a fault worth
/// someone's attention, and a stream of 403s or offline errors would bury them.
@Suite("API diagnostics")
struct APIDiagnosticsTests {
    nonisolated final class CapturingSink: DiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var incidents: [DiagnosticIncident] = []
        var all: [DiagnosticIncident] { lock.withLock { incidents } }
        func submit(_ incident: DiagnosticIncident) { lock.withLock { incidents.append(incident) } }
        func flush() {}
    }

    private static let server = URL(string: "https://jellyfin.example.com")!

    private static func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = "GET"
        return request
    }

    @Test(arguments: [401, 403, 304])
    func anExpectedStatusIsHistoryOnly(status: Int) {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        APIDiagnostics.statusFailed(status, request: Self.request("Items/12c4"), serverURL: Self.server, client: "jellyfin", startedAt: 0, hub: hub)
        #expect(sink.all.isEmpty)
        #expect(hub.snapshot().map(\.code) == [status == 401 ? .apiSessionExpired : .apiFailure])
    }

    @Test func anUnexpectedStatusIsAnIncident() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        APIDiagnostics.statusFailed(500, request: Self.request("Users/8f3a/Items/12c4/PlaybackInfo"), serverURL: Self.server, client: "jellyfin", startedAt: 0, hub: hub)
        let incident = try #require(sink.all.first)
        #expect(sink.all.count == 1)
        #expect(incident.code == .apiRequestFailed)
        #expect(incident.fingerprint == ["api.requestFailed", "jellyfin", "Users.id.Items.id.PlaybackInfo", "status500"])
        #expect(incident.fields["httpStatus"] == .int(500))
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost])
    func beingOfflineIsHistoryOnly(code: URLError.Code) {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        APIDiagnostics.transportFailed(URLError(code), request: Self.request("Items/12c4"), serverURL: Self.server, client: "jellyfin", startedAt: 0, hub: hub)
        #expect(sink.all.isEmpty)
        #expect(hub.snapshot().map(\.code) == [.apiFailure])
    }

    @Test func aTLSFailureIsAnIncident() {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        APIDiagnostics.transportFailed(URLError(.secureConnectionFailed), request: Self.request("Items/12c4"), serverURL: Self.server, client: "jellyfin", startedAt: 0, hub: hub)
        #expect(sink.all.map(\.code) == [.apiRequestFailed])
    }

    /// A cancel is the app's own doing, not even history.
    @Test func aCancelIsNotRecorded() {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        APIDiagnostics.transportFailed(CancellationError(), request: Self.request("Items"), serverURL: Self.server, client: "jellyfin", startedAt: 0, hub: hub)
        APIDiagnostics.transportFailed(URLError(.cancelled), request: Self.request("Items"), serverURL: Self.server, client: "jellyfin", startedAt: 0, hub: hub)
        #expect(sink.all.isEmpty)
        #expect(hub.snapshot().isEmpty)
    }
}
