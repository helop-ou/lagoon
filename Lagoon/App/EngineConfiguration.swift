import Foundation
import LagoonEngine

/// App-owned wiring of the playback package: where its tuning knobs come
/// from, and where its diagnostics go.
///
/// The engine used to reach into `UserDefaults.standard` for keys spelled
/// `debug.…` and record diagnostics against an enum only this app had a
/// schema for. Both were the package knowing things about its host. Now the
/// engine states what it wants and discards what nobody collects, and this
/// is the one place that answers.
nonisolated enum EngineConfiguration {
    /// Called once from the app's initialiser, before anything plays.
    static func install() {
        EngineTuning.use { tuning(from: .standard) }
        EngineDiagnostics.use(EngineDiagnosticsBridge())
    }

    /// Read afresh each time the engine asks, not snapshotted at launch:
    /// several of these are read at the start of each playback, and a
    /// tester toggling one in Settings expects the next playback to differ.
    static func tuning(from defaults: UserDefaults) -> EngineTuning {
        var tuning = EngineTuning()
        tuning.stripsDolbyVisionEnhancementLayer = defaults.bool(forKey: "debug.stripDoviEL")
        tuning.marksDroppableFrames = defaults.bool(forKey: "debug.markDroppableFrames")
        tuning.runsFrameLossBench = defaults.bool(forKey: "debug.frameLossBench")
        tuning.tracesDecodeThreads = defaults.bool(forKey: "debug.decodeTrace")
        tuning.profilesAV1Pipeline = defaults.bool(forKey: "debug.av1PipelineProfile")
        tuning.logsPlaybackLifecycle = defaults.bool(forKey: "debug.playbackLifecycleLog")
        tuning.hostShowsPlaybackHUD = defaults.bool(forKey: "debug.playbackHUD")
        tuning.buffersOnAudioStarvation = defaults.bool(forKey: "debug.bufferOnAudioStarvation")
        tuning.cachesSegmentedManifests = defaults.bool(forKey: "debug.experimentalPlaybackCache")
        tuning.rendererRetirementDelaySeconds = defaults.double(
            forKey: "debug.regressionRendererRetirementDelaySeconds"
        )
        // Absent means "let the decoder choose", which is not the same as
        // false — so these two stay nil unless someone set them.
        tuning.softwareDecodeOutputMode = defaults.string(forKey: "debug.softwareDecodeOutputMode")
        if defaults.object(forKey: "debug.softwareDecodeCompressedOutput") != nil {
            tuning.softwareDecodeCompressedOutput = defaults.bool(
                forKey: "debug.softwareDecodeCompressedOutput"
            )
        }
        #if DEBUG
        // Forcing a small cache cap is a debug-build affordance, as it was
        // when the engine read the key itself. The engine honours the value
        // in any build; this is the app declining to offer it in Release.
        tuning.cacheCapacityMegabytes = defaults.integer(forKey: "debug.playbackCacheCapMB")
        #endif
        return tuning
    }
}

/// Carries the engine's diagnostics into the app's own history and reports.
///
/// The engine names events in its own vocabulary; this maps them to the
/// stable codes every dashboard query and grouping rule already uses. The
/// hub decides what reporting is on and what a report costs — the engine
/// never knows either.
struct EngineDiagnosticsBridge: EngineDiagnosticSink {
    func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue]) {
        Diagnostics.shared.record(Self.code(for: event), fields)
    }

    @discardableResult
    func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool {
        Diagnostics.shared.report(
            Self.code(for: incident),
            level: Self.level(for: level),
            variant: variant,
            fields: fields
        )
    }

    static func code(for event: EngineDiagnosticEvent) -> DiagnosticEventCode {
        switch event {
        case .playbackPlay: .playbackPlay
        case .playbackPause: .playbackPause
        case .playbackSeek: .playbackSeek
        case .playbackFinished: .playbackFinished
        case .playbackTrack: .playbackTrack
        case .playbackStallBegin: .playbackStallBegin
        case .playbackStallEnd: .playbackStallEnd
        case .playbackRendererRecovery: .playbackRendererRecovery
        case .playbackCacheFallback: .playbackCacheFallback
        case .playbackSubtitleLoadFailed: .playbackSubtitleLoadFailed
        }
    }

    static func code(for incident: EngineDiagnosticIncident) -> DiagnosticIncidentCode {
        switch incident {
        case .playbackStall: .playbackStall
        case .playbackRendererRecovery: .playbackRendererRecovery
        case .playbackSubtitleLoadFailed: .playbackSubtitleLoadFailed
        }
    }

    static func level(for level: EngineDiagnosticLevel) -> DiagnosticLevel {
        switch level {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}
