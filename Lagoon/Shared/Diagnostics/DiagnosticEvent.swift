import Foundation
import LagoonEngine

/// Stable codes: dashboards query them, so add, never rename.
nonisolated enum DiagnosticEventCode: String, Sendable, CaseIterable {
    case playbackStart = "playback.start"
    case playbackReady = "playback.ready"
    case playbackPlay = "playback.play"
    case playbackPause = "playback.pause"
    case playbackSeek = "playback.seek"
    case playbackTrack = "playback.track"
    case playbackSubtitleLoadFailed = "playback.subtitleLoadFailed"
    case playbackStallBegin = "playback.stallBegin"
    case playbackStallEnd = "playback.stallEnd"
    case playbackRendererRecovery = "playback.rendererRecovery"
    case playbackCacheFallback = "playback.cacheFallback"
    case playbackSample = "playback.sample"
    case playbackFallback = "playback.fallback"
    case playbackHandoffBegin = "playback.handoffBegin"
    case playbackHandoffEnd = "playback.handoffEnd"
    case playbackFinished = "playback.finished"
    case playbackStop = "playback.stop"
    case playbackFailure = "playback.failure"
    /// Watch Together: membership and transport, never which group, item
    /// or people.
    case syncPlayJoin = "syncplay.join"
    case syncPlayLeave = "syncplay.leave"
    case syncPlayCommand = "syncplay.command"
    case syncPlayDrift = "syncplay.drift"
    case audioInterruption = "audio.interruption"
    case audioRoute = "audio.route"
    case apiFailure = "api.failure"
    case apiSessionExpired = "api.sessionExpired"
    case appMemoryWarning = "app.memoryWarning"
    case appThermal = "app.thermal"
    case appForeground = "app.foreground"
    case appBackground = "app.background"
}

nonisolated enum DiagnosticLevel: String, Sendable, Comparable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Fields are validated on construction against `DiagnosticSchema`.
nonisolated struct DiagnosticEvent: Equatable, Sendable {
    let code: DiagnosticEventCode
    /// `ProcessInfo.systemUptime`. History is reported as offsets from the
    /// incident, never wall-clock time.
    let uptime: TimeInterval
    let fields: [String: DiagnosticValue]

    init(code: DiagnosticEventCode, uptime: TimeInterval, fields: [String: DiagnosticValue] = [:]) {
        self.code = code
        self.uptime = uptime
        let validated = DiagnosticSchema.validated(fields)
        var accepted = validated.accepted
        if validated.rejected > 0 {
            accepted["schemaRejected"] = .int(validated.rejected)
        }
        self.fields = accepted
    }

    /// Seconds relative to `reference` (negative before it).
    func jsonObject(relativeTo reference: TimeInterval) -> [String: Any] {
        var object: [String: Any] = [
            "t": (uptime - reference).rounded(toPlaces: 3),
            "code": code.rawValue,
        ]
        if !fields.isEmpty {
            object["fields"] = fields.mapValues(\.jsonObject)
        }
        return object
    }
}
