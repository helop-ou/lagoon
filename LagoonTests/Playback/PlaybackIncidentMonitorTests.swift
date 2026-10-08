import Foundation
import os
import Testing
import LagoonEngine
@testable import Lagoon

/// The monitor against a test hub: what the controller's calls turn into.
@MainActor
@Suite("Playback incident monitor")
struct PlaybackIncidentMonitorTests {
    nonisolated final class CapturingSink: DiagnosticSink, Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [DiagnosticIncident]())
        var incidents: [DiagnosticIncident] { state.withLock { $0 } }
        func submit(_ incident: DiagnosticIncident) { state.withLock { $0.append(incident) } }
        func flush() {}
    }

    /// Deliberately completes sleeps even after cancellation: a timer
    /// completion racing opt-out, replacement, or dismissal must be harmless.
    nonisolated final class SamplingClock: Sendable {
        private struct State {
            var waits: [CheckedContinuation<Void, Never>] = []
            var requests = 0
            var cancellations = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var requests: Int { state.withLock { $0.requests } }
        var cancellations: Int { state.withLock { $0.cancellations } }

        func sleep(for duration: Duration) async throws {
            #expect(duration == .seconds(2))
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    state.withLock {
                        $0.requests += 1
                        $0.waits.append(continuation)
                    }
                }
            } onCancel: {
                self.state.withLock { $0.cancellations += 1 }
            }
        }

        func advance() {
            let next = state.withLock { $0.waits.isEmpty ? nil : $0.waits.removeFirst() }
            next?.resume()
        }

        func finish() {
            let waits = state.withLock {
                let waits = $0.waits
                $0.waits = []
                return waits
            }
            for wait in waits { wait.resume() }
        }
    }

    static func waitUntil(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        // Waits on scheduling, not the interval (SamplingClock drives that).
        // Parallel decoder suites can hog the simulator for seconds.
        try await Polling.untilMainActor(timeout: .seconds(10), pollInterval: .milliseconds(1), condition: condition)
        try #require(condition(), sourceLocation: sourceLocation)
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
            message: "The stream could not be opened (https://lagoonfix.example.eu/Videos/12c4/stream?api_key=secret-token).",
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

        // Remux fails too: the fallback resolves as failed and the ladder is spent.
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

    /// Incidents say whether picture in picture or AirPlay still showed the
    /// picture. The engine's own reports inherit the display state too.
    @Test func incidentsSayWhatShowedThePictureWhileTheAppWasAway() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.setDisplayState(background: true, pictureInPicture: true, airPlay: false, videoSuspended: false)
        _ = hub.report(.playbackRendererRecovery, level: .warning, fields: ["recovery": .string("decodeSessionRebuilt")])
        let engineReport = try #require(sink.incidents.first)
        #expect(engineReport.fields["appState"] == .string("background"))
        #expect(engineReport.fields["pictureInPicture"] == .bool(true))
        #expect(engineReport.fields["airPlay"] == .bool(false))
        #expect(engineReport.fields["videoSuspended"] == .bool(false))

        // Picture in picture stopped in the background: video suspended.
        monitor.setDisplayState(background: true, pictureInPicture: false, airPlay: false, videoSuspended: true)
        monitor.engineFailed(Self.failure(), delivery: .negotiated, next: nil, engine: nil)
        let failed = try #require(sink.incidents.last)
        #expect(failed.code == .playbackFailed)
        #expect(failed.fields["pictureInPicture"] == .bool(false))
        #expect(failed.fields["videoSuspended"] == .bool(true))
    }

    /// The link's rate rides on every incident, the engine's own stall reports
    /// included, in the unit of the title's `bitrate`, so a slow link can be
    /// told from an engine problem.
    @Test func incidentsCarryTheLinksMeasuredRate() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.observeLinkRate(bytesPerSecond: nil)
        _ = hub.report(.playbackStall, level: .warning, variant: ["reprime", "video"])
        #expect(sink.incidents.last?.fields["networkBitrate"] == nil)

        // 1.6 MB/s is 12.8 Mbit/s: barely above the title's 12 Mbit/s.
        monitor.observeLinkRate(bytesPerSecond: 1_600_000)
        _ = hub.report(.playbackStall, level: .warning, variant: ["reprime", "video"])
        let stall = try #require(sink.incidents.last)
        #expect(stall.fields["networkBitrate"] == .int(12_800_000))
        #expect(stall.fields["bitrate"] == .int(12_000_000))

        // A new attempt starts unmeasured.
        monitor.endAttempt(engine: nil, outcome: "stopped")
        monitor.beginAttempt(delivery: .remux, method: .transcode, source: try Self.source(), cached: false, disc: false, resumeSeconds: 0)
        _ = hub.report(.playbackStall, level: .warning, variant: ["sustained", "video"])
        #expect(sink.incidents.last?.fields["networkBitrate"] == nil)
    }

    @Test func theLinkRateIsRoundedToATenthOfAMegabit() {
        #expect(PlaybackIncidentMonitor.networkBitrate(nil) == nil)
        #expect(PlaybackIncidentMonitor.networkBitrate(0) == nil)
        #expect(PlaybackIncidentMonitor.networkBitrate(.infinity) == nil)
        #expect(PlaybackIncidentMonitor.networkBitrate(1_234_567) == 9_900_000)
        #expect(PlaybackIncidentMonitor.networkBitrate(5_000) == 0)
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
        // No attempt exists yet, so the token is omitted, not sent empty.
        #expect(incident.fields["attempt"] == nil)
        #expect(incident.fields["schemaRejected"] == nil)
        // The server's message names the title and its path.
        for value in incident.fields.values {
            let text = "\(value.jsonObject)"
            #expect(!text.contains("Transcoding"))
            #expect(!text.contains("Nobody"))
            #expect(!text.contains("secret"))
        }
    }

    /// The source names the title and its path, and the engine's message
    /// carries a stream URL with the access token. None of it may leave the
    /// device, in an incident's own fields or in the history riding along.
    @Test func noIncidentCarriesTheTitleThePathOrTheToken() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.engineFailed(Self.failure(), delivery: .negotiated, next: .remux, engine: nil)
        monitor.endAttempt(engine: nil, outcome: "fallback")
        monitor.beginAttempt(delivery: .remux, method: .transcode, source: try Self.source(), cached: false, disc: false, resumeSeconds: 42)
        monitor.engineFailed(Self.failure(.read), delivery: .remux, next: nil, engine: nil)
        monitor.startFailed(
            JellyfinError.server(status: 500, message: "No stream for The Film Nobody Should See at /media/secret/The Film.mkv"),
            delivery: .transcode,
            stage: .negotiate
        )
        #expect(sink.incidents.map(\.code) == [.playbackFallback, .playbackFailed, .playbackStartFailed])

        let values = sink.incidents.flatMap { incident in
            Array(incident.fields.values) + incident.history.flatMap { Array($0.fields.values) }
        }
        #expect(!values.isEmpty)
        for value in values {
            let text = "\(value.jsonObject)"
            for secret in ["Nobody", "The Film", "/media", "api_key", "secret-token", "lagoonfix"] {
                #expect(!text.contains(secret), "\(secret) in \(text)")
            }
        }
    }

    @Test func aDismissalDuringNegotiationIsNotAStartFailure() {
        let cancelled = URLError(.cancelled)
        #expect(PlaybackController.isStartCancellation(cancelled, taskCancelled: true, closed: false))
        #expect(PlaybackController.isStartCancellation(cancelled, taskCancelled: false, closed: true))
        #expect(PlaybackController.isStartCancellation(CancellationError(), taskCancelled: false, closed: false))
        // A -999 nobody asked for is the transport's failure and still reports.
        #expect(!PlaybackController.isStartCancellation(cancelled, taskCancelled: false, closed: false))
        #expect(!PlaybackController.isStartCancellation(URLError(.timedOut), taskCancelled: true, closed: true))
    }

    @Test func optingOutCancelsTheTimerAndOptingBackInStartsAFreshWindow() async throws {
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let hub = DiagnosticsHub(reportingEnabled: { enabled.withLock { $0 } })
        let notifications = NotificationCenter()
        let clock = SamplingClock()
        let monitor = PlaybackIncidentMonitor(hub: hub, notificationCenter: notifications, sleep: clock.sleep)
        let engine = SampleBufferPlayerEngine()
        defer {
            monitor.endAttempt(engine: engine, outcome: "stopped")
            engine.shutdown()
            clock.finish()
        }
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.playbackReady(engine: engine)
        try await Self.waitUntil { clock.requests == 1 }
        // Two ticks are just short of writing the next history sample.
        clock.advance()
        try await Self.waitUntil { clock.requests == 2 }
        clock.advance()
        try await Self.waitUntil { clock.requests == 3 }

        enabled.withLock { $0 = false }
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        try await Self.waitUntil { clock.cancellations == 1 }
        let beforeOptIn = hub.snapshot()
        #expect(!beforeOptIn.contains { $0.code == .playbackSample })

        enabled.withLock { $0 = true }
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        try await Self.waitUntil { clock.requests == 4 }
        // The cancelled timer returns after opt-in; it must not write a tick
        // or cancel the new timer.
        clock.advance()
        clock.advance()
        try await Self.waitUntil { clock.requests == 5 }
        #expect(hub.snapshot() == beforeOptIn)
        #expect(clock.cancellations == 1)
        clock.advance()
        try await Self.waitUntil { clock.requests == 6 }
        #expect(hub.snapshot() == beforeOptIn)
        clock.advance()
        try await Self.waitUntil { clock.requests == 7 }
        #expect(hub.snapshot().filter { $0.code == .playbackSample }.count == 1)
    }

    @Test func anOptedOutAttemptCanEnableSamplingAndAnEndedAttemptCannotRestartIt() async throws {
        let enabled = OSAllocatedUnfairLock(initialState: false)
        let hub = DiagnosticsHub(reportingEnabled: { enabled.withLock { $0 } })
        let notifications = NotificationCenter()
        let clock = SamplingClock()
        let monitor = PlaybackIncidentMonitor(hub: hub, notificationCenter: notifications, sleep: clock.sleep)
        let engine = SampleBufferPlayerEngine()
        defer {
            monitor.endAttempt(engine: engine, outcome: "stopped")
            engine.shutdown()
            clock.finish()
        }
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.playbackReady(engine: engine)
        // Let any incorrectly-created timer enter its injected sleep.
        try await Task.sleep(for: .milliseconds(10))
        #expect(clock.requests == 0)
        #expect(hub.snapshot().isEmpty)
        enabled.withLock { $0 = true }
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        try await Self.waitUntil { clock.requests == 1 }
        // Unrelated defaults writes must not replace a running sampler.
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        monitor.endAttempt(engine: engine, outcome: "stopped")
        let endedHistory = hub.snapshot()
        clock.advance()
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(10))
        #expect(clock.requests == 1)
        #expect(clock.cancellations == 1)
        #expect(hub.snapshot() == endedHistory)
    }

    @Test func releasingTheMonitorCancelsSamplingWithoutRetainingTheEngine() async throws {
        let clock = SamplingClock()
        var monitor: PlaybackIncidentMonitor? = PlaybackIncidentMonitor(
            hub: DiagnosticsHub(reportingEnabled: { true }),
            notificationCenter: NotificationCenter(),
            sleep: clock.sleep
        )
        var engine: SampleBufferPlayerEngine? = SampleBufferPlayerEngine()
        weak let releasedEngine = engine
        weak let releasedMonitor = monitor
        defer {
            engine?.shutdown()
            clock.finish()
        }
        monitor?.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor?.playbackReady(engine: try #require(engine))
        try await Self.waitUntil { clock.requests == 1 }
        engine?.shutdown()
        engine = nil
        try await Self.waitUntil { releasedEngine == nil }
        monitor = nil
        #expect(releasedMonitor == nil)
        #expect(clock.cancellations == 1)
    }

    @Test func aQueuedOptOutDoesNotInvalidateTheNextAttempt() async throws {
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let hub = DiagnosticsHub(reportingEnabled: { enabled.withLock { $0 } })
        let notifications = NotificationCenter()
        let clock = SamplingClock()
        let monitor = PlaybackIncidentMonitor(hub: hub, notificationCenter: notifications, sleep: clock.sleep)
        let outgoing = SampleBufferPlayerEngine()
        let successor = SampleBufferPlayerEngine()
        defer {
            monitor.endAttempt(engine: successor, outcome: "stopped")
            outgoing.shutdown()
            successor.shutdown()
            clock.finish()
        }
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.playbackReady(engine: outgoing)
        try await Self.waitUntil { clock.requests == 1 }

        // The preference callback is queued on MainActor; opt back in before
        // it runs.
        enabled.withLock { $0 = false }
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        monitor.endAttempt(engine: outgoing, outcome: "handoff")
        enabled.withLock { $0 = true }
        monitor.beginAttempt(delivery: .negotiated, method: .directPlay, source: try Self.source(), cached: true, disc: false, resumeSeconds: 0)
        monitor.playbackReady(engine: successor)
        let successorAttempt = monitor.attempt
        try await Self.waitUntil { clock.requests == 2 }
        // The late callback must keep the successor's cadence and summary
        // eligibility.
        clock.advance()
        for expectedRequests in 3...5 {
            clock.advance()
            try await Self.waitUntil { clock.requests == expectedRequests }
        }
        #expect(clock.cancellations == 1)
        #expect(monitor.sampledWholeAttempt)
        let samples = hub.snapshot().filter { $0.code == .playbackSample }
        #expect(samples.count == 1)
        #expect(samples.first?.fields["attempt"] == .string(successorAttempt))
    }
}
