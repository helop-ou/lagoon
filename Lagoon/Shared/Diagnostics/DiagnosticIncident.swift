import Foundation

/// Stable codes for reported incidents. These are the grouping keys on the
/// dashboard, so the same rule as event codes applies: add, never rename.
nonisolated enum DiagnosticIncidentCode: String, Sendable, CaseIterable {
    /// Negotiation or engine start never produced a playing engine.
    case playbackStartFailed = "playback.startFailed"
    /// The engine failed and the delivery ladder is trying another rung.
    /// A recovered incident: the viewer sees a reload, not an error.
    case playbackFallback = "playback.fallback"
    /// The engine failed and nothing is left to try. Terminal.
    case playbackFailed = "playback.failed"
    /// An AVFoundation renderer was replaced or flushed to keep playing.
    case playbackRendererRecovery = "playback.rendererRecovery"
    /// A stall the engine's own recovery handled, but one long enough or
    /// frequent enough that the viewer noticed.
    case playbackStall = "playback.stall"
    /// The playhead stopped advancing while playback was expected to run
    /// and no stall or error was raised. The class of bug nobody can
    /// reproduce from a description.
    case playbackFrozen = "playback.frozen"
    /// A session that ended without an error but with counters over the
    /// documented thresholds.
    case playbackDegraded = "playback.degraded"
    /// A server-side subtitle could not be loaded; playback continued.
    case playbackSubtitleLoadFailed = "playback.subtitleLoadFailed"
    /// The next episode did not take over.
    case playbackHandoffFailed = "playback.handoffFailed"
    /// A Jellyfin or Seerr request failed in a way that is not an expected
    /// offline or authentication condition.
    case apiRequestFailed = "api.requestFailed"
    /// A response the app could not decode: a contract drift, or a bug.
    case apiDecodeFailed = "api.decodeFailed"
}

/// Where a playback failure happened and what the underlying layer said,
/// in codes only. `PlaybackEngineFailure.message` stays the viewer's
/// sentence; this is the reporter's.
nonisolated struct PlaybackFailureDetail: Equatable, Sendable {
    enum Stage: String, Sendable {
        case negotiate, open, seek, read, decode, videoRenderer, audioRenderer, subtitle, cache, start, handoff, unknown
    }

    let stage: Stage
    /// A token such as `AVFoundationErrorDomain`, `VideoToolbox`, `ffmpeg`,
    /// or `NSURLErrorDomain`. Nil when the layer gave none.
    let domain: String?
    let code: Int?

    init(stage: Stage, domain: String? = nil, code: Int? = nil) {
        self.stage = stage
        self.domain = domain
        self.code = code
    }

    /// Domain and code from any error, and nothing else from it: not the
    /// description, not `userInfo`, which is where URLs and file names live.
    init(stage: Stage, error: Error?) {
        guard let error else {
            self.init(stage: stage)
            return
        }
        let nsError = error as NSError
        self.init(stage: stage, domain: nsError.domain, code: nsError.code)
    }

    var fields: [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = ["stage": .string(stage.rawValue)]
        if let domain = DiagnosticSchema.token(domain) {
            fields["errorDomain"] = domain
        }
        if let code {
            fields["errorCode"] = .int(code)
        }
        return fields
    }

    /// The part of the fingerprint that separates one kind of failure at a
    /// stage from another.
    var fingerprint: [String] {
        var parts = [stage.rawValue]
        if let domain, DiagnosticSchema.isToken(domain) {
            parts.append(domain)
        }
        if let code {
            parts.append(String(code))
        }
        return parts
    }
}

/// One report. Built by `DiagnosticsHub` from validated fields, a history
/// snapshot, and the process context; handed to the sink as a value.
nonisolated struct DiagnosticIncident: Equatable, Sendable {
    let id: UUID
    let code: DiagnosticIncidentCode
    let level: DiagnosticLevel
    /// The incident code followed by variant tokens. Sentry groups on it
    /// verbatim, so it must be stable across builds and never contain a
    /// value that varies per occurrence (a position, a duration).
    let fingerprint: [String]
    let fields: [String: DiagnosticValue]
    let history: [DiagnosticEvent]
    /// How many times this fingerprint fired since the last report of it,
    /// including this one. Suppressed repeats are folded in here.
    let occurrences: Int
    let timestamp: Date
    let uptime: TimeInterval

    init(
        id: UUID = UUID(),
        code: DiagnosticIncidentCode,
        level: DiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue],
        history: [DiagnosticEvent],
        occurrences: Int,
        timestamp: Date,
        uptime: TimeInterval
    ) {
        self.id = id
        self.code = code
        self.level = level
        self.fingerprint = [code.rawValue] + variant.filter(DiagnosticSchema.isToken)
        var merged = fields
        merged["occurrences"] = .int(max(occurrences, 1))
        let validated = DiagnosticSchema.validated(merged)
        var accepted = validated.accepted
        if validated.rejected > 0 {
            accepted["schemaRejected"] = .int(validated.rejected)
        }
        self.fields = accepted
        self.history = history
        self.occurrences = max(occurrences, 1)
        self.timestamp = timestamp
        self.uptime = uptime
    }

    /// The history attachment, as the object `JSONSerialization` writes.
    var historyJSONObject: [String: Any] {
        [
            "incident": id.uuidString.lowercased(),
            "code": code.rawValue,
            "events": history.map { $0.jsonObject(relativeTo: uptime) },
        ]
    }
}
