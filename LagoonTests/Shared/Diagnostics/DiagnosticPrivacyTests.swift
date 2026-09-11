import Foundation
import Testing
@testable import Lagoon

/// Acceptance criterion 4 of HEL-159, as a test: drive the production
/// reporting paths (the API helper both clients call, and the playback
/// monitor the controller owns) with synthetic sensitive values, then
/// assert none of them reach the bytes that would leave the device.
///
/// The token charset is a backstop, not the guarantee: a bare hostname
/// such as `nas.local` would pass it. The guarantee is that these entry
/// points only ever hand the schema identifiers, which is what this test
/// pins.
@MainActor
@Suite("Diagnostic privacy")
struct DiagnosticPrivacyTests {
    static let sensitive = [
        "fixture.example.eu", "secret-token-9f8e7d", "demo-user", "The Film Nobody Should See",
        "api_key", "connect.sid", "sessionCookieValue", "Bearer", "It was the best of times",
        "/media/secret", "12c4", "8f3a1c2e", "MediaBrowser",
    ]

    final class CapturingSink: DiagnosticSink, @unchecked Sendable {
        let lock = NSLock()
        var incidents: [DiagnosticIncident] = []
        func submit(_ incident: DiagnosticIncident) { lock.lock(); incidents.append(incident); lock.unlock() }
        func flush() {}
    }

    static let context = DiagnosticContext(
        bundleIdentifier: "ee.helop.lagoon", appVersion: "0.1", build: "95", osName: "tvOS",
        osVersion: "26.0", deviceModel: "AppleTV14,1", isSimulator: true, environment: "debug", engineVersion: "lavf62.3.100"
    )

    static func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fixture.example.eu/jf/Users/8f3a1c2e/Items/12c4/PlaybackInfo?api_key=secret-token-9f8e7d")!)
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Token=\"secret-token-9f8e7d\"", forHTTPHeaderField: "Authorization")
        request.setValue("connect.sid=sessionCookieValue", forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{\"Name\":\"The Film Nobody Should See\"}".utf8)
        return request
    }

    @Test func nothingSensitiveSurvivesTheProductionEntryPoints() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let server = URL(string: "https://fixture.example.eu/jf")!

        // The API helper, as both clients call it.
        let transportError = NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "A secure connection to fixture.example.eu could not be made",
            NSURLErrorFailingURLErrorKey: Self.request().url! as Any,
        ])
        APIDiagnostics.transportFailed(transportError, request: Self.request(), serverURL: server, client: "jellyfin", startedAt: 0, hub: hub)
        APIDiagnostics.statusFailed(500, request: Self.request(), serverURL: server, client: "jellyfin", startedAt: 0, hub: hub)
        struct Probe: Decodable { let name: String }
        var decodeError: Error?
        do { _ = try JSONDecoder().decode(Probe.self, from: Data("{\"Name\":\"demo-user\"}".utf8)) } catch { decodeError = error }
        APIDiagnostics.decodeFailed(try #require(decodeError), request: Self.request(), serverURL: server, client: "seerr", hub: hub)

        // The playback monitor, with a media source full of names and
        // paths, an engine failure quoting the server, and a start failure
        // carrying the server's own sentence.
        let monitor = PlaybackIncidentMonitor(hub: hub)
        let source = try JellyfinClient.decoder.decode(MediaSource.self, from: Data(#"""
        {"Id":"12c4","Name":"The Film Nobody Should See","Path":"/media/secret/The Film.mkv","Container":"mkv",
         "TranscodingUrl":"/Videos/12c4/master.m3u8?api_key=secret-token-9f8e7d",
         "MediaStreams":[{"Type":"Video","Codec":"hevc","Profile":"Main 10","VideoRangeType":"HDR10","Width":3840,"Height":2160,"DisplayTitle":"The Film Nobody Should See"},
                         {"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true,"Title":"demo-user commentary"},
                         {"Type":"Subtitle","Codec":"subrip","DeliveryUrl":"/Videos/12c4/Subtitles?api_key=secret-token-9f8e7d"}]}
        """#.utf8))
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: source, cached: true, disc: false, resumeSeconds: 12)
        monitor.engineFailed(
            PlaybackEngineFailure(
                cause: .delivery,
                message: "The stream could not be opened (https://fixture.example.eu/Videos/12c4/stream?api_key=secret-token-9f8e7d: It was the best of times).",
                detail: DemuxError.openFailed("Server returned 5XX for The Film Nobody Should See", code: -1094995529).diagnosticDetail
            ),
            delivery: .negotiated, next: nil, engine: nil
        )
        monitor.endAttempt(engine: nil, outcome: "failed")
        monitor.startFailed(
            JellyfinError.server(status: 500, message: "Transcoding failed for The Film Nobody Should See at /media/secret"),
            delivery: .remux, stage: .negotiate
        )
        // A subtitle load failure as the engine reports it.
        hub.report(
            .playbackSubtitleLoadFailed, level: .warning,
            variant: PlaybackFailureDetail(stage: .subtitle, error: transportError).fingerprint,
            fields: PlaybackFailureDetail(stage: .subtitle, error: transportError).fields
        )

        let dsn = try #require(SentryDSN(string: "https://key@o1.ingest.de.sentry.io/1"))
        #expect(sink.incidents.map(\.code) == [.apiRequestFailed, .apiRequestFailed, .apiDecodeFailed, .playbackFailed, .playbackStartFailed, .playbackSubtitleLoadFailed])
        for incident in sink.incidents {
            let envelope = try #require(SentryEnvelope.make(incident: incident, context: Self.context, dsn: dsn))
            let text = String(decoding: envelope.data, as: UTF8.self)
            for value in Self.sensitive {
                #expect(!text.contains(value), "\(incident.code.rawValue) leaked \(value)")
            }
        }
        // And the useful parts did arrive.
        let api = sink.incidents[0]
        #expect(api.fields["route"] == .string("Users/{id}/Items/{id}/PlaybackInfo"))
        #expect(api.fields["errorDomain"] == .string("NSURLErrorDomain"))
        #expect(api.fields["errorCode"] == .int(URLError.secureConnectionFailed.rawValue))
        let decode = sink.incidents[2]
        #expect(decode.fields["decodingKey"] == .string("name"))
        let playback = sink.incidents[3]
        #expect(playback.fields["videoCodec"] == .string("hevc"))
        #expect(playback.fields["errorCode"] == .int(-1094995529))
        #expect(playback.fields["schemaRejected"] == nil)
    }

    @Test func aCallerMistakeIsDroppedAndCounted() throws {
        // A title or a hostname handed to a token key never reaches the
        // envelope, and the drop is visible in the report.
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        hub.report(.playbackFailed, level: .error, fields: [
            "videoProfile": .string("The Film Nobody Should See"),
            "errorDomain": .string("fixture.example.eu"),
            "container": .string("mkv"),
        ])
        let incident = try #require(sink.incidents.first)
        #expect(incident.fields["videoProfile"] == nil)
        #expect(incident.fields["errorDomain"] == nil)
        #expect(incident.fields["container"] == .string("mkv"))
        #expect(incident.fields["schemaRejected"] == .int(2))
    }
}
