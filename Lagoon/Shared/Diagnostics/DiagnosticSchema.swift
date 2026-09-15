import Foundation

/// One value inside a diagnostic event or incident. Deliberately narrow:
/// numbers, flags, and short tokens. There is no place for a sentence, a
/// URL, a title, or an error's `localizedDescription`, which is how the
/// allowlist in `DiagnosticSchema` stays the only thing that can reach the
/// reporting backend (HEL-159).
nonisolated enum DiagnosticValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)

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

/// What a schema key accepts. Strings are the only kind that could carry
/// private content, so each string key is either a closed choice or a
/// bounded token: letters, digits, `.`, `_`, `-` and `,`, never whitespace,
/// `/`, `:`, `@` or `?`, which rules out URLs, hostnames-with-paths, query
/// strings, and prose. A hostname alone would pass the token test, which is
/// why hostnames must never be handed to a token key in the first place and
/// why the sensitive-payload test in `DiagnosticPrivacyTests` drives the
/// real entry points with one.
nonisolated enum DiagnosticFieldKind: Equatable, Sendable {
    case int
    case double
    case bool
    /// `[A-Za-z0-9._,-]{1,48}`.
    case token
    /// A route template such as `Users/{id}/Items/{id}`: path segments of
    /// letters or the literal `{id}`, joined by `/`. Produced only by
    /// `DiagnosticRouteTemplate`, which replaces every other segment.
    case route
    case choice(Set<String>)
}

/// The complete allowlist of fields a diagnostic event or incident may
/// carry, and the only place it is defined. A key that is not here is
/// dropped at construction time; a value that does not fit its kind is
/// dropped too. `schemaRejected` counts what was dropped so a mistake at a
/// call site shows up in the report instead of silently vanishing.
nonisolated enum DiagnosticSchema {
    static let tokenMaximumLength = 48
    /// A failure incident carries the attempt's facts, the pipeline
    /// snapshot and its own detail, around fifty keys; the cap only has to
    /// stop a runaway caller.
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
    /// SyncPlay's four transport commands, and how a drift was corrected
    /// (HEL-172). The correction has its own key rather than reusing
    /// `method`, which is Jellyfin's delivery method and a different
    /// closed set.
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
        // How the item is delivered and what it is made of. Codec, container
        // and range names are FFmpeg/Jellyfin identifiers, never titles.
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
        "retry": .bool,
        // Watch Together (HEL-172). Numbers and closed choices only: a
        // group has a name, an id, participants and an item, and none of
        // them belongs in a report.
        "command": .choice(syncPlayCommandChoices),
        "leadMs": .int,
        "driftMs": .int,
        "correction": .choice(syncPlayCorrectionChoices),
    ]

    /// Keeps the fields the schema admits, in the form it admits them.
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

    /// The charset admits `fixture.example.eu` and `192.168.1.10`, which no
    /// identifier this app reports ever looks like. A dotted token whose
    /// last label is two or three lowercase letters, or whose labels are
    /// all numeric, is treated as an address and refused. Error domains
    /// (`NSURLErrorDomain`, `com.apple.coreaudio.avfaudio`), codec names,
    /// and versions (`lavf62.3.100`) all pass.
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
            // The version exception must match `DiagnosticRouteTemplate`'s, or
            // a route it emits would be rejected here and the field dropped.
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

    /// A token from arbitrary text, or nil. Used where a caller holds an
    /// identifier that is expected to be a token (an error domain, a codec
    /// name) so an unexpected value is dropped rather than truncated into
    /// something misleading.
    static func token(_ text: String?) -> DiagnosticValue? {
        guard let text, isToken(text) else { return nil }
        return .string(text)
    }
}
