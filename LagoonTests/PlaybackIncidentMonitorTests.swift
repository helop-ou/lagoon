import Foundation
import Testing
@testable import Lagoon

/// The monitor against a test hub: what the controller's calls turn into.
@MainActor
@Suite("Playback incident monitor")
struct PlaybackIncidentMonitorTests {
    final class CapturingSink: DiagnosticSink, @unchecked Sendable {
        let lock = NSLock()
        var incidents: [DiagnosticIncident] = []
        func submit(_ incident: DiagnosticIncident) { lock.lock(); incidents.append(incident); lock.unlock() }
        func flush() {}
    }

    static func source() throws -> MediaSource {
        try JellyfinClient.decoder.decode(MediaSource.self, from: Data(#"""
        {"Id":"12c4","Name":"The Film Nobody Should See","Path":"/media/secret/The Film.mkv","Container":"mkv",
         "Bitrate":12000000,"RunTimeTicks":60000000000,
         "MediaStreams":[{"Type":"Video","Codec":"hevc","Profile":"Main 10","VideoRangeType":"HDR10","Width":3840,"Height":2160,"BitDepth":10,"RealFrameRate":23.976,"DisplayTitle":"4K HDR"},
                         {"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true,"DisplayTitle":"English Atmos"}]}
        """#.utf8))
    }

    static func failure(_ stage: PlaybackFailureDetail.Stage = .open) -> PlaybackEngineFailure {
        PlaybackEngineFailure(
            cause: .delivery,
            message: "The stream could not be opened (https://fixture.example.eu/Videos/12c4/stream?api_key=secret-token).",
            detail: PlaybackFailureDetail(stage: stage, domain: "ffmpeg", code: -1094995529)
        )
    }

    @Test func aFallbackIsReportedOnlyOnceTheNextRungHasAVerdict() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.engineFailed(Self.failure(), delivery: .negotiated, next: .remux, engine: nil)
        // Nothing yet: the remux rung has not answered.
        #expect(sink.incidents.isEmpty)
        monitor.endAttempt(engine: nil, outcome: "fallback")
        #expect(sink.incidents.isEmpty)

        // The remux rung fails too: the fallback resolves as failed, then
        // the ladder is spent.
        monitor.beginAttempt(delivery: .remux, method: .transcode, source: try Self.source(), cached: false, disc: false, resumeSeconds: 42)
        monitor.engineFailed(Self.failure(.read), delivery: .remux, next: nil, engine: nil)
        #expect(sink.incidents.map(\.code) == [.playbackFallback, .playbackFailed])
        let fallback = sink.incidents[0]
        #expect(fallback.level == .error)
        #expect(fallback.fields["outcome"] == .string("failed"))
        #expect(fallback.fields["from"] == .string("negotiated"))
        #expect(fallback.fields["to"] == .string("remux"))
        #expect(fallback.fields["elapsedMs"] != nil)
        #expect(fallback.fingerprint == ["playback.fallback", "delivery", "open", "ffmpeg", "-1094995529"])
        let failed = sink.incidents[1]
        #expect(failed.fields["outcome"] == .string("exhausted"))
        #expect(failed.fingerprint == ["playback.failed", "delivery", "read", "ffmpeg", "-1094995529"])
        // The attempt's facts ride along as tags; the title and path do not.
        #expect(failed.fields["videoCodec"] == .string("hevc"))
        #expect(failed.fields["videoRange"] == .string("HDR10"))
        #expect(failed.fields["audioCodec"] == .string("eac3"))
        #expect(failed.fields["delivery"] == .string("remux"))
    }

    @Test func aFallbackAbandonedByTheViewerSaysSo() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.engineFailed(Self.failure(), delivery: .negotiated, next: .remux, engine: nil)
        monitor.endAttempt(engine: nil, outcome: "fallback")
        monitor.beginAttempt(delivery: .remux, method: .transcode, source: try Self.source(), cached: false, disc: false, resumeSeconds: 0)
        monitor.endAttempt(engine: nil, outcome: "stopped")
        #expect(sink.incidents.map(\.code) == [.playbackFallback])
        #expect(sink.incidents[0].fields["outcome"] == .string("cancelled"))
    }

    @Test func aFallbackThatPlaysIsReportedAsRecovered() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.engineFailed(Self.failure(), delivery: .negotiated, next: .remux, engine: nil)
        monitor.endAttempt(engine: nil, outcome: "fallback")
        monitor.beginAttempt(delivery: .remux, method: .transcode, source: try Self.source(), cached: false, disc: false, resumeSeconds: 0)
        let engine = SampleBufferPlayerEngine()
        monitor.playbackReady(engine: engine)
        monitor.endAttempt(engine: engine, outcome: "stopped")
        #expect(sink.incidents.map(\.code) == [.playbackFallback])
        #expect(sink.incidents[0].level == .warning)
        #expect(sink.incidents[0].fields["outcome"] == .string("recovered"))
        engine.shutdown()
    }

    @Test func aStartFailureCarriesTheServerStatusNotItsMessage() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.startFailed(
            JellyfinError.server(status: 500, message: "Transcoding failed for The Film Nobody Should See at /media/secret"),
            delivery: .negotiated,
            stage: .negotiate
        )
        let incident = try #require(sink.incidents.first)
        #expect(incident.code == .playbackStartFailed)
        #expect(incident.fields["httpStatus"] == .int(500))
        #expect(incident.fields["errorDomain"] == .string("JellyfinError.server"))
        #expect(incident.fingerprint == ["playback.startFailed", "negotiate", "JellyfinError.server", "500"])
    }
}
