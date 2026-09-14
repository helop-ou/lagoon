import Foundation

/// Stable codes for the rolling history. Renaming one changes what every
/// dashboard query and grouping rule sees, so add rather than rename.
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
    /// Watch Together (HEL-172). Group membership and the transport the
    /// server drives; never which group, which item or who is in it.
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

/// One entry in the rolling history. Fields are validated on construction,
/// so an event can only ever hold what `DiagnosticSchema` admits.
nonisolated struct DiagnosticEvent: Equatable, Sendable {
    let code: DiagnosticEventCode
    /// `ProcessInfo.systemUptime` when recorded. History is expressed as
    /// offsets from the incident that carries it, never as wall-clock time.
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

    /// The attachment form: seconds relative to `reference` (negative
    /// before it), the code, and the fields.
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

nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
