import Foundation
import LagoonEngine

/// Stable codes and dashboard grouping keys: add, never rename.
nonisolated enum DiagnosticIncidentCode: String, Sendable, CaseIterable {
    /// Negotiation or engine start never produced a playing engine.
    case playbackStartFailed = "playback.startFailed"
    /// The engine failed and the ladder is trying another rung. Recovered:
    /// the viewer sees a reload.
    case playbackFallback = "playback.fallback"
    /// Nothing is left to try. Terminal.
    case playbackFailed = "playback.failed"
    /// An AVFoundation renderer was replaced or flushed to keep playing.
    case playbackRendererRecovery = "playback.rendererRecovery"
    /// A recovered stall long or frequent enough to notice.
    case playbackStall = "playback.stall"
    /// The playhead stopped with no stall or error raised.
    case playbackFrozen = "playback.frozen"
    /// Ended without error but with counters over the thresholds.
    case playbackDegraded = "playback.degraded"
    /// A server-side subtitle could not be loaded; playback continued.
    case playbackSubtitleLoadFailed = "playback.subtitleLoadFailed"
    /// The next episode did not take over.
    case playbackHandoffFailed = "playback.handoffFailed"
    /// A request failed for a reason other than offline or auth.
    case apiRequestFailed = "api.requestFailed"
    /// A response the app could not decode.
    case apiDecodeFailed = "api.decodeFailed"
}

/// One report, built by `DiagnosticsHub`.
nonisolated struct DiagnosticIncident: Equatable, Sendable {
    let id: UUID
    let code: DiagnosticIncidentCode
    let level: DiagnosticLevel
    /// Code plus variant tokens. Sentry groups on it verbatim, so never put
    /// a per-occurrence value (position, duration) in it.
    let fingerprint: [String]
    let fields: [String: DiagnosticValue]
    let history: [DiagnosticEvent]
    /// Occurrences since the last report, including this one and suppressed
    /// repeats.
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

    var historyJSONObject: [String: Any] {
        [
            "incident": id.uuidString.lowercased(),
            "code": code.rawValue,
            "events": history.map { $0.jsonObject(relativeTo: uptime) },
        ]
    }
}
