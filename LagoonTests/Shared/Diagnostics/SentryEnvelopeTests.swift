import Foundation
import Testing
@testable import Lagoon

@Suite("Sentry envelope")
struct SentryEnvelopeTests {
    static let context = DiagnosticContext(
        bundleIdentifier: "ee.helop.lagoon",
        appVersion: "0.1",
        build: "95",
        osName: "tvOS",
        osVersion: "26.0",
        deviceModel: "AppleTV14,1",
        isSimulator: false,
        environment: "testflight",
        engineVersion: "lavf62.3.100"
    )
    static let dsn = SentryDSN(string: "https://abc123@o4512064306282496.ingest.de.sentry.io/4512064311722064")!

    static func incident(
        fields: [String: DiagnosticValue] = ["stage": .string("open"), "errorDomain": .string("ffmpeg"), "errorCode": .int(-1094995529)],
        history: [DiagnosticEvent] = []
    ) -> DiagnosticIncident {
        DiagnosticIncident(
            id: UUID(uuidString: "0123ABCD-0000-4000-8000-000000000001")!,
            code: .playbackFailed,
            level: .error,
            variant: ["delivery", "open", "ffmpeg", "-1094995529"],
            fields: fields,
            history: history,
            occurrences: 3,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            uptime: 500
        )
    }

    @Test func dsnParsesHostedAndSelfHostedForms() throws {
        let hosted = try #require(SentryDSN(string: "https://key@o1.ingest.de.sentry.io/42"))
        #expect(hosted.publicKey == "key")
        #expect(hosted.projectID == "42")
        #expect(hosted.envelopeURL?.absoluteString == "https://o1.ingest.de.sentry.io/api/42/envelope/")
        #expect(hosted.authorizationHeader == "Sentry sentry_version=7, sentry_client=lagoon.diagnostics/1.0.0, sentry_key=key")
        let local = try #require(SentryDSN(string: "http://key@127.0.0.1:8765/sentry/7"))
        #expect(local.envelopeURL?.absoluteString == "http://127.0.0.1:8765/sentry/api/7/envelope/")
        #expect(SentryDSN(string: "https://o1.ingest.sentry.io/42") == nil)
        #expect(SentryDSN(string: "https://key@host/notanumber") == nil)
        #expect(SentryDSN(string: "ftp://key@host/1") == nil)
    }

    @Test func eventCarriesReleaseFingerprintTagsAndNoUser() throws {
        let event = SentryEnvelope.eventJSONObject(incident: Self.incident(), context: Self.context, eventID: "e1")
        #expect(event["release"] as? String == "ee.helop.lagoon@0.1+95")
        #expect(event["dist"] as? String == "95")
        #expect(event["environment"] as? String == "testflight")
        // Never "cocoa" or "javascript": Sentry infers an IP address and a
        // location for those platforms unless a project setting says not to.
        #expect(event["platform"] as? String == "native")
        #expect(event["level"] as? String == "error")
        #expect(event["fingerprint"] as? [String] == ["playback.failed", "delivery", "open", "ffmpeg", "-1094995529"])
        #expect(event["user"] == nil)
        #expect(event["breadcrumbs"] == nil)
        #expect(event["server_name"] == nil)
        let tags = try #require(event["tags"] as? [String: String])
        #expect(tags["build"] == "95")
        #expect(tags["model"] == "AppleTV14,1")
        #expect(tags["stage"] == "open")
        #expect(tags["errorDomain"] == "ffmpeg")
        let exception = try #require((event["exception"] as? [String: Any])?["values"] as? [[String: Any]]).first
        #expect(exception?["type"] as? String == "playback.failed")
        #expect(exception?["value"] as? String == "delivery open ffmpeg -1094995529 ×3")
        let extra = try #require(event["extra"] as? [String: Any])
        #expect(extra["errorCode"] as? Int == -1094995529)
        #expect(extra["occurrences"] as? Int == 3)
    }

    @Test func envelopeIsFramedWithExactLengthsAndAnAttachment() throws {
        let history = [DiagnosticEvent(code: .playbackSeek, uptime: 498, fields: ["position": .double(12)])]
        let envelope = try #require(SentryEnvelope.make(incident: Self.incident(history: history), context: Self.context, dsn: Self.dsn))
        #expect(envelope.eventID == "0123abcd000040008000000000000001")
        var lines = envelope.data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        #expect(lines.last?.isEmpty == true)
        lines.removeLast()
        #expect(lines.count == 5)
        let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        #expect(header["event_id"] as? String == envelope.eventID)
        #expect((header["sdk"] as? [String: String])?["name"] == "lagoon.diagnostics")
        let eventHeader = try #require(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        #expect(eventHeader["type"] as? String == "event")
        #expect(eventHeader["length"] as? Int == lines[2].count)
        let attachmentHeader = try #require(try JSONSerialization.jsonObject(with: Data(lines[3])) as? [String: Any])
        #expect(attachmentHeader["type"] as? String == "attachment")
        #expect(attachmentHeader["filename"] as? String == "history.json")
        #expect(attachmentHeader["length"] as? Int == lines[4].count)
        let attachment = try #require(try JSONSerialization.jsonObject(with: Data(lines[4])) as? [String: Any])
        let events = try #require(attachment["events"] as? [[String: Any]])
        #expect(events.count == 1)
        #expect(events[0]["t"] as? Double == -2)
        #expect(events[0]["code"] as? String == "playback.seek")
    }

    @Test func oversizedFieldsNeverReachTheEnvelope() throws {
        // A caller that hands a schema a sentence or a URL loses it here.
        let incident = Self.incident(fields: [
            "stage": .string("open"),
            "message": .string("The stream https://fixture.example.eu/Items/x could not be opened"),
            "route": .string("Items/12c4"),
        ])
        let envelope = try #require(SentryEnvelope.make(incident: incident, context: Self.context, dsn: Self.dsn))
        let text = String(decoding: envelope.data, as: UTF8.self)
        #expect(!text.contains("fixture"))
        #expect(!text.contains("could not be opened"))
        #expect(!text.contains("12c4"))
        #expect(text.contains("\"schemaRejected\":2"))
    }
}

@Suite("Sentry transport policy")
struct SentryTransportPolicyTests {
    @Test func responsesAreClassified() {
        let policy = SentryTransportPolicy.standard
        #expect(policy.outcome(status: 200, headers: [:]) == .accepted(pauseFor: nil))
        // Sentry can ask for a pause on a success; the next envelope waits.
        #expect(policy.outcome(status: 200, headers: ["X-Sentry-Rate-Limits": "60:error:organization"]) == .accepted(pauseFor: 60))
        #expect(policy.outcome(status: 200, headers: ["X-Sentry-Rate-Limits": "60:transaction:organization"]) == .accepted(pauseFor: nil))
        #expect(policy.outcome(status: 429, headers: ["Retry-After": "120"]) == .retryAfter(120))
        #expect(policy.outcome(status: 429, headers: [:]) == .retryAfter(60))
        #expect(policy.outcome(status: 400, headers: [:]) == .discard)
        #expect(policy.outcome(status: 413, headers: [:]) == .discard)
        #expect(policy.outcome(status: 408, headers: [:]) == .backoff)
        #expect(policy.outcome(status: 503, headers: [:]) == .backoff)
    }

    @Test func sentryRateLimitHeaderWinsAndOnlyForErrorCategories() {
        let policy = SentryTransportPolicy.standard
        #expect(policy.retryDelay(headers: ["x-sentry-rate-limits": "60:transaction:organization, 2700:error;security:organization"]) == 2700)
        #expect(policy.retryDelay(headers: ["X-Sentry-Rate-Limits": "300::organization"]) == 300)
        #expect(policy.retryDelay(headers: ["X-Sentry-Rate-Limits": "60:transaction:organization", "Retry-After": "15"]) == 15)
        #expect(policy.retryDelay(headers: ["X-Sentry-Rate-Limits": "garbage"]) == 60)
        #expect(policy.rateLimit(headers: [:]) == nil)
        #expect(policy.rateLimit(headers: ["X-Sentry-Rate-Limits": "0:error:organization"]) == nil)
    }

    @Test func backoffDoublesFromThirtySecondsAndCapsAtAnHour() {
        let policy = SentryTransportPolicy.standard
        #expect(policy.backoff(afterConsecutiveFailures: 0) == 0)
        #expect(policy.backoff(afterConsecutiveFailures: 1) == 30)
        #expect(policy.backoff(afterConsecutiveFailures: 2) == 60)
        #expect(policy.backoff(afterConsecutiveFailures: 4) == 240)
        #expect(policy.backoff(afterConsecutiveFailures: 20) == 3_600)
    }
}
