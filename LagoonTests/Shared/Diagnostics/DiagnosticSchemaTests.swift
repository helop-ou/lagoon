import Foundation
import os
import Testing
@testable import Lagoon

@Suite("Diagnostic schema")
struct DiagnosticSchemaTests {
    @Test func unknownKeysAndWrongKindsAreDroppedAndCounted() {
        let event = DiagnosticEvent(code: .playbackSample, uptime: 10, fields: [
            "position": .double(12.5),
            "title": .string("The Film Nobody Should See"),
            "position2": .int(3),
            "delivery": .string("magic"),
            "width": .string("1920"),
        ])
        #expect(event.fields["position"] == .double(12.5))
        #expect(event.fields["title"] == nil)
        #expect(event.fields["delivery"] == nil)
        #expect(event.fields["width"] == nil)
        #expect(event.fields["schemaRejected"] == .int(4))
    }

    @Test func tokensRejectAnythingThatCouldCarryContent() {
        #expect(DiagnosticSchema.isToken("hevc"))
        #expect(DiagnosticSchema.isToken("AVFoundationErrorDomain"))
        #expect(DiagnosticSchema.isToken("gpu-sdr-linear"))
        #expect(DiagnosticSchema.isToken("AppleTV14,1"))
        #expect(!DiagnosticSchema.isToken("The Film"))
        #expect(!DiagnosticSchema.isToken("https://fixture.example.eu/Items/1"))
        #expect(!DiagnosticSchema.isToken("user@example.com"))
        #expect(!DiagnosticSchema.isToken("a/b"))
        #expect(!DiagnosticSchema.isToken("fixture.example.eu"))
        #expect(!DiagnosticSchema.isToken("demo.jellyfin.org"))
        #expect(!DiagnosticSchema.isToken("192.168.1.10"))
        #expect(DiagnosticSchema.isToken("com.apple.coreaudio.avfaudio"))
        #expect(DiagnosticSchema.isToken("VideoToolbox.decode"))
        #expect(DiagnosticSchema.isToken("lavf62.3.100"))
        #expect(!DiagnosticSchema.isToken(""))
        #expect(!DiagnosticSchema.isToken(String(repeating: "x", count: 49)))
        #expect(DiagnosticSchema.token("https://example.com") == nil)
    }

    @Test func routesAreLettersOrPlaceholdersOnly() {
        #expect(DiagnosticSchema.isRoute("Users/{id}/Items/{id}/PlaybackInfo"))
        #expect(!DiagnosticSchema.isRoute("Users/8f3a/Items"))
        #expect(!DiagnosticSchema.isRoute("Items?api_key=secret"))
    }

    @Test func nonFiniteNumbersAreRejected() {
        let validated = DiagnosticSchema.validated(["position": .double(.nan), "rate": .double(.infinity)])
        #expect(validated.accepted.isEmpty)
        #expect(validated.rejected == 2)
    }

    @Test func everyChoiceAndTokenKeyIsAStringKindAndEveryCodeIsUnique() {
        for (key, kind) in DiagnosticSchema.fields {
            if case .choice(let choices) = kind {
                #expect(!choices.isEmpty, "\(key) has no choices")
                #expect(choices.allSatisfy(DiagnosticSchema.isToken), "\(key) choices must be tokens")
            }
        }
        let eventCodes = DiagnosticEventCode.allCases.map(\.rawValue)
        #expect(Set(eventCodes).count == eventCodes.count)
        let incidentCodes = DiagnosticIncidentCode.allCases.map(\.rawValue)
        #expect(Set(incidentCodes).count == incidentCodes.count)
        #expect(incidentCodes.allSatisfy(DiagnosticSchema.isToken))
    }
}

@Suite("Diagnostics preference")
struct DiagnosticsPreferenceTests {
    @Test func launchArgumentsAndToggleValuesBothCount() {
        #expect(DiagnosticsPreference.isReportingEnabled(storedValue: true))
        #expect(!DiagnosticsPreference.isReportingEnabled(storedValue: false))
        #expect(DiagnosticsPreference.isReportingEnabled(storedValue: "YES"))
        #expect(DiagnosticsPreference.isReportingEnabled(storedValue: "1"))
        #expect(!DiagnosticsPreference.isReportingEnabled(storedValue: "NO"))
        #expect(DiagnosticsPreference.isReportingEnabled(storedValue: NSNumber(value: 1)))
        #expect(DiagnosticsPreference.isReportingEnabled(storedValue: nil) == DiagnosticsPreference.defaultReportingEnabled)
    }
}

@Suite("Diagnostic history")
struct DiagnosticHistoryTests {
    @Test func historyIsBoundedByCountAndWindow() {
        var history = DiagnosticHistory(capacity: 3, window: 10)
        for index in 0..<5 {
            history.append(DiagnosticEvent(code: .playbackSample, uptime: TimeInterval(index * 4)))
        }
        #expect(history.events.count == 3)
        #expect(history.events.map(\.uptime) == [8, 12, 16])
        // At uptime 20 the window keeps 10 s: events at 12 and 16.
        #expect(history.snapshot(at: 20).map(\.uptime) == [12, 16])
        #expect(history.lastUptime(of: .playbackSample) == 16)
        #expect(history.lastUptime(of: .playbackSeek) == nil)
    }

    @Test func snapshotOffsetsAreRelativeToTheIncident() {
        let event = DiagnosticEvent(code: .playbackSeek, uptime: 95.25, fields: ["position": .double(30)])
        let object = event.jsonObject(relativeTo: 100)
        #expect(object["t"] as? Double == -4.75)
        #expect(object["code"] as? String == "playback.seek")
        #expect((object["fields"] as? [String: Any])?["position"] as? Double == 30)
    }
}

@Suite("Incident suppression")
struct IncidentSuppressorTests {
    @Test func repeatsFoldIntoOccurrencesAndTheWindowResets() {
        var suppressor = IncidentSuppressor(limits: .init(perFingerprint: 2, perWindow: 10, perProcess: 100, window: 60))
        let key = ["playback.stall", "sustained"]
        #expect(suppressor.decide(fingerprint: key, now: 0) == .report(occurrences: 1))
        #expect(suppressor.decide(fingerprint: key, now: 1) == .report(occurrences: 1))
        #expect(suppressor.decide(fingerprint: key, now: 2) == .suppress)
        #expect(suppressor.decide(fingerprint: key, now: 3) == .suppress)
        // A different fingerprint is unaffected.
        #expect(suppressor.decide(fingerprint: ["api.requestFailed"], now: 3) == .report(occurrences: 1))
        // Once the hour passes, the next report carries the folded count.
        #expect(suppressor.decide(fingerprint: key, now: 61) == .report(occurrences: 3))
    }

    @Test func globalCapsHoldAcrossFingerprints() {
        var suppressor = IncidentSuppressor(limits: .init(perFingerprint: 10, perWindow: 2, perProcess: 3, window: 60))
        #expect(suppressor.decide(fingerprint: ["a"], now: 0) == .report(occurrences: 1))
        #expect(suppressor.decide(fingerprint: ["b"], now: 0) == .report(occurrences: 1))
        #expect(suppressor.decide(fingerprint: ["c"], now: 0) == .suppress)
        #expect(suppressor.decide(fingerprint: ["c"], now: 61) == .report(occurrences: 2))
        // Process cap: three sent, the fourth never goes.
        #expect(suppressor.decide(fingerprint: ["d"], now: 200) == .suppress)
    }
}

@Suite("Diagnostics hub")
struct DiagnosticsHubTests {
    nonisolated final class CapturingSink: DiagnosticSink, Sendable {
        private struct State {
            var incidents: [DiagnosticIncident] = []
            var flushes = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var incidents: [DiagnosticIncident] { state.withLock { $0.incidents } }
        var flushes: Int { state.withLock { $0.flushes } }
        func submit(_ incident: DiagnosticIncident) {
            state.withLock { $0.incidents.append(incident) }
        }
        func flush() { state.withLock { $0.flushes += 1 } }
    }

    @Test func reportsCarryTheHistoryAndRespectTheSwitch() throws {
        let sink = CapturingSink()
        let uptime = OSAllocatedUnfairLock<TimeInterval>(initialState: 100)
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let hub = DiagnosticsHub(
            history: DiagnosticHistory(capacity: 10, window: 30),
            sink: sink,
            uptime: { uptime.withLock { $0 } },
            now: { Date(timeIntervalSince1970: 1_000) },
            reportingEnabled: { enabled.withLock { $0 } }
        )
        hub.record(.playbackStart, ["delivery": .string("negotiated")])
        uptime.withLock { $0 = 110 }
        hub.record(.playbackSeek, ["position": .double(42)])
        uptime.withLock { $0 = 111 }
        #expect(hub.millisecondsSince(.playbackSeek) == 1_000)
        #expect(hub.report(.playbackFailed, level: .error, variant: ["delivery", "open"], fields: ["stage": .string("open")]))
        let incident = try #require(sink.incidents.first)
        #expect(incident.fingerprint == ["playback.failed", "delivery", "open"])
        #expect(incident.history.map(\.code) == [.playbackStart, .playbackSeek])
        #expect(incident.fields["stage"] == .string("open"))
        #expect(incident.fields["occurrences"] == .int(1))
        #expect(incident.uptime == 111)

        enabled.withLock { $0 = false }
        #expect(!hub.report(.playbackFailed, level: .error))
        #expect(sink.incidents.count == 1)
        hub.flush()
        #expect(sink.flushes == 1)
    }

    @Test func ambientFieldsAreInheritedUntilCleared() throws {
        let sink = CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        hub.setAmbientFields(["attempt": .string("ab12cd34"), "videoCodec": .string("hevc"), "position": .double(1)])
        hub.report(.playbackStall, level: .warning, variant: ["reprime"], fields: ["position": .double(42)])
        let stall = try #require(sink.incidents.last)
        #expect(stall.fields["attempt"] == .string("ab12cd34"))
        #expect(stall.fields["videoCodec"] == .string("hevc"))
        // The incident's own value wins over the ambient one.
        #expect(stall.fields["position"] == .double(42))
        hub.setAmbientFields([:])
        hub.report(.apiRequestFailed, level: .warning, variant: ["x"])
        #expect(sink.incidents.last?.fields["attempt"] == nil)
    }

    @Test func aFullIncidentKeepsEveryFieldUnderTheCap() {
        // A failure carries facts, pipeline snapshot and detail: about fifty
        // keys. None of them may fall off the end alphabetically.
        var fields: [String: DiagnosticValue] = [:]
        for key in ["attempt", "audioChannels", "audioCodec", "audioLead", "audioPath", "audioQueued", "audioStalls",
                    "audioStarvation", "availableMB", "bitDepth", "bitrate", "buffering", "cached", "cause", "container",
                    "corrupted", "delivery", "disc", "dropped", "durationSeconds", "frameDelay", "frameRate", "frames",
                    "from", "height", "idleRequests", "memoryMB", "method", "outcome", "paused", "playedSeconds",
                    "position", "rate", "reprimes", "stage", "stalls", "thermal", "to", "videoCodec", "videoIntake",
                    "videoPath", "videoProfile", "videoRange", "width", "appState", "errorDomain", "errorCode",
                    "sinceSeekMs", "sinceTrackSwitchMs"] {
            fields[key] = DiagnosticSchema.fields[key].map { kind -> DiagnosticValue in
                switch kind {
                case .int: .int(1)
                case .double: .double(1)
                case .bool: .bool(true)
                case .token: .string("hevc")
                case .route: .string("Items")
                case .choice(let choices): .string(choices.sorted()[0])
                }
            }
        }
        let validated = DiagnosticSchema.validated(fields)
        #expect(validated.rejected == 0)
        #expect(validated.accepted.count == fields.count)
    }

    @Test func recordingStopsWhenReportingIsOff() {
        let enabled = OSAllocatedUnfairLock(initialState: false)
        let hub = DiagnosticsHub(reportingEnabled: { enabled.withLock { $0 } })
        hub.record(.playbackPlay)
        #expect(hub.snapshot().isEmpty)
        #expect(!hub.isReportingEnabled)
        enabled.withLock { $0 = true }
        hub.record(.playbackPlay)
        #expect(hub.snapshot().count == 1)
    }

    @Test func nothingIsReportedWithoutASink() {
        let hub = DiagnosticsHub(reportingEnabled: { true })
        #expect(!hub.report(.playbackFrozen, level: .error))
        hub.record(.playbackPlay)
        #expect(hub.snapshot().count == 1)
    }
}
