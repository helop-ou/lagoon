import Foundation
import LagoonEngine

/// Where the engine's tuning knobs come from and where its diagnostics go.
/// The engine knows nothing about the host's defaults keys or schemas.
nonisolated enum EngineConfiguration {
    /// Called once from the app's initialiser, before anything plays.
    static func install() {
        EngineTuning.use { tuning(from: .standard) }
        EngineDiagnostics.use(EngineDiagnosticsBridge())
    }

    /// Read afresh on each request, so a Settings toggle affects the next
    /// playback.
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
        // Absent means "let the decoder choose", not false; keep nil unless set.
        tuning.softwareDecodeOutputMode = defaults.string(forKey: "debug.softwareDecodeOutputMode")
        if defaults.object(forKey: "debug.softwareDecodeCompressedOutput") != nil {
            tuning.softwareDecodeCompressedOutput = defaults.bool(
                forKey: "debug.softwareDecodeCompressedOutput"
            )
        }
        #if DEBUG
        // Debug builds only; the engine would honour it in any build.
        tuning.cacheCapacityMegabytes = defaults.integer(forKey: "debug.playbackCacheCapMB")
        #endif
        return tuning
    }
}

/// Maps engine diagnostics onto the app's stable codes, which dashboard
/// queries and grouping rules depend on.
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
