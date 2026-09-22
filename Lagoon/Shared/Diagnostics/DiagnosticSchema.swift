import Foundation
import LagoonEngine

/// What a schema key accepts. Strings could carry private content, so each
/// is a closed choice or a bounded token, which rules out URLs and prose. A
/// bare hostname passes the token test, so never pass one to a token key;
/// `DiagnosticPrivacyTests` checks this.
nonisolated enum DiagnosticFieldKind: Equatable, Sendable {
    case int
    case double
    case bool
    /// `[A-Za-z0-9._,-]{1,48}`.
    case token
    /// `Users/{id}/Items/{id}`, produced only by `DiagnosticRouteTemplate`.
    case route
    case choice(Set<String>)
}

/// The only allowlist of diagnostic fields. Unknown keys and ill-fitting
/// values are dropped and counted in `schemaRejected`, so call-site mistakes
/// show up in the report.
nonisolated enum DiagnosticSchema {
    static let tokenMaximumLength = 48
    /// A failure carries about fifty keys; the cap only stops a runaway
    /// caller.
    static let maximumFieldsPerRecord = 64

    static let deliveryChoices: Set<String> = ["negotiated", "remux", "transcode"]
    static let methodChoices: Set<String> = ["DirectPlay", "DirectStream", "Transcode"]
    static let causeChoices: Set<String> = ["undecodable", "delivery"]
    static let stageChoices: Set<String> = [
        "negotiate", "open", "seek", "read", "decode", "videoRenderer",
        "audioRenderer", "subtitle", "cache", "start", "handoff", "unknown",
    ]
    static let recoveryChoices: Set<String> = [
        "rendererFailed", "mediaServicesReset", "requiresFlush", "restartPoint",
        "stallReprime", "stallResume", "cacheFallback",
        // A VideoToolbox session rebuilt rather than read as undecodable, and
        // one that needed no rebuild.
        "decodeSessionRebuilt", "decodeSessionIgnored",
    ]
    static let outcomeChoices: Set<String> = [
        "recovered", "reprimed", "failed", "exhausted", "cancelled", "ready",
        "finished", "stopped", "handoff", "fallback",
    ]
    static let trackChoices: Set<String> = ["audio", "subtitle"]
    static let trackSourceChoices: Set<String> = ["embedded", "external", "downloaded", "off"]
    static let thermalChoices: Set<String> = ["nominal", "fair", "serious", "critical"]
    static let appStateChoices: Set<String> = ["active", "inactive", "background"]
    static let interruptionChoices: Set<String> = ["began", "ended", "endedResume"]
    static let stallCauseChoices: Set<String> = ["video", "audio", "none"]
    static let httpMethodChoices: Set<String> = ["GET", "POST", "DELETE", "PUT"]
    static let clientChoices: Set<String> = ["jellyfin", "seerr", "media", "image", "subtitle"]
    static let networkChoices: Set<String> = ["unrestricted", "constrained", "expensive", "unknown"]
    /// SyncPlay's transport commands and drift corrections. The correction
    /// has its own key: `method` is Jellyfin's delivery method.
    static let syncPlayCommandChoices: Set<String> = ["unpause", "pause", "seek", "stop"]
    static let syncPlayCorrectionChoices: Set<String> = ["none", "rate", "seek"]
    static let degradationChoices: Set<String> = [
        "droppedFrames", "stalls", "reprimes", "audioStarvation", "frozen", "rendererRecovery",
    ]

    static let fields: [String: DiagnosticFieldKind] = [
        // Identity of the attempt and the record.
        "attempt": .token,
        "occurrences": .int,
        "schemaRejected": .int,
        // Delivery and format: FFmpeg/Jellyfin identifiers, never titles.
        "delivery": .choice(deliveryChoices),
        "method": .choice(methodChoices),
        "container": .token,
        "videoCodec": .token,
        "videoProfile": .token,
        "videoRange": .token,
        "audioCodec": .token,
        "audioChannels": .int,
        "width": .int,
        "height": .int,
        "bitDepth": .int,
        "frameRate": .double,
        "bitrate": .int,
        "durationSeconds": .double,
        "disc": .bool,
        "cached": .bool,
        "videoPath": .token,
        "audioPath": .token,
        "network": .choice(networkChoices),
        // Where the playhead was and how the pipeline looked.
        "position": .double,
        "rate": .double,
        "paused": .bool,
        "buffering": .bool,
        "videoQueued": .int,
        "audioQueued": .int,
        "videoIntake": .int,
        "audioLead": .double,
        "stalls": .int,
        "audioStalls": .int,
        "audioStarvation": .int,
        "reprimes": .int,
        "idleRequests": .int,
        "dropped": .int,
        "corrupted": .int,
        "frames": .int,
        "frameDelay": .double,
        "memoryMB": .double,
        "availableMB": .double,
        "thermal": .choice(thermalChoices),
        "appState": .choice(appStateChoices),
        "playedSeconds": .double,
        "elapsedMs": .double,
        "sinceSeekMs": .double,
        "sinceTrackSwitchMs": .double,
        "frozenSeconds": .double,
        "frozenCount": .int,
        "rendererRecoveries": .int,
        "fallbacks": .int,
        "degradation": .token,
        // What went wrong, in codes only.
        "stage": .choice(stageChoices),
        "cause": .choice(causeChoices),
        "recovery": .choice(recoveryChoices),
        "outcome": .choice(outcomeChoices),
        "from": .choice(deliveryChoices),
        "to": .choice(deliveryChoices),
        "errorDomain": .token,
        "errorCode": .int,
        "httpStatus": .int,
        "httpMethod": .choice(httpMethodChoices),
        "route": .route,
        "client": .choice(clientChoices),
        "decodingKey": .token,
        "track": .choice(trackChoices),
        "trackSource": .choice(trackSourceChoices),
        "stallCause": .choice(stallCauseChoices),
        "interruption": .choice(interruptionChoices),
        "routeReason": .token,
        "samplesSinceFlush": .int,
        "startPointDrops": .int,
        /// The refused sample, in media ms: separates a restart-point failure
        /// from a verdict on the stream.
        "refusedSampleMs": .int,
        "retry": .bool,
        // Watch Together: numbers and closed choices only, never the group's
        // name, id, participants or item.
        "command": .choice(syncPlayCommandChoices),
        "leadMs": .int,
        "driftMs": .int,
        "correction": .choice(syncPlayCorrectionChoices),
    ]

    static func validated(
        _ fields: [String: DiagnosticValue]
    ) -> (accepted: [String: DiagnosticValue], rejected: Int) {
        var accepted: [String: DiagnosticValue] = [:]
        var rejected = 0
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard accepted.count < maximumFieldsPerRecord,
                  let kind = Self.fields[key],
                  accepts(kind, value) else {
                rejected += 1
                continue
            }
            accepted[key] = value
        }
        return (accepted, rejected)
    }

    static func accepts(_ kind: DiagnosticFieldKind, _ value: DiagnosticValue) -> Bool {
        switch (kind, value) {
        case (.int, .int):
            return true
        case (.double, .double(let number)):
            return number.isFinite
        case (.double, .int):
            return true
        case (.bool, .bool):
            return true
        case (.token, .string(let text)):
            return isToken(text)
        case (.route, .string(let text)):
            return isRoute(text)
        case (.choice(let choices), .string(let text)):
            return choices.contains(text)
        default:
            return false
        }
    }

    static func isToken(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= tokenMaximumLength else { return false }
        let charactersAllowed = text.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ","):
                true
            default:
                false
            }
        }
        return charactersAllowed && !looksLikeAnAddress(text)
    }

    /// Refuses addresses the charset would admit: a dotted token whose last
    /// label is two or three lowercase letters, or all-numeric labels. Error
    /// domains, codecs and versions (`lavf62.3.100`) pass.
    static func looksLikeAnAddress(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        if let last = labels.last, (2...3).contains(last.count),
           last.allSatisfy({ $0.isLowercase && $0.isLetter }) {
            return true
        }
        return labels.count >= 3 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func isRoute(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 120 else { return false }
        return text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            // Must match `DiagnosticRouteTemplate`'s version exception.
            if segment == "{id}" || DiagnosticRouteTemplate.isVersionSegment(segment) {
                return true
            }
            return !segment.isEmpty && segment.utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    true
                default:
                    false
                }
            }
        }
    }

    /// A token from text, or nil: an unexpected value is dropped, not
    /// truncated into something misleading.
    static func token(_ text: String?) -> DiagnosticValue? {
        guard let text, isToken(text) else { return nil }
        return .string(text)
    }
}

nonisolated extension DiagnosticValue {
    /// The Foundation object `JSONSerialization` accepts for this value.
    var jsonObject: Any {
        switch self {
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .string(let value): value
        }
    }
}
