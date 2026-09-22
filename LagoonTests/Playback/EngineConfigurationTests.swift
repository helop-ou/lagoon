import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// The app's side of the engine's two configuration seams.
@Suite("Engine configuration")
struct EngineConfigurationTests {
    @Test func everyKnobComesFromTheKeyThatUsedToBeReadInsideTheEngine() {
        let suiteName = "EngineConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Nothing set: a plain build runs uninstrumented.
        let untouched = EngineConfiguration.tuning(from: defaults)
        #expect(!untouched.runsFrameLossBench)
        #expect(!untouched.profilesAV1Pipeline)
        #expect(!untouched.cachesSegmentedManifests)
        #expect(untouched.softwareDecodeOutputMode == nil)
        #expect(untouched.softwareDecodeCompressedOutput == nil)
        #expect(untouched.rendererRetirementDelaySeconds == 0)

        for key in [
            "debug.stripDoviEL", "debug.markDroppableFrames", "debug.frameLossBench",
            "debug.decodeTrace", "debug.av1PipelineProfile", "debug.playbackLifecycleLog",
            "debug.playbackHUD", "debug.bufferOnAudioStarvation",
            "debug.experimentalPlaybackCache",
        ] {
            defaults.set(true, forKey: key)
        }
        defaults.set("gpu-sdr-linear", forKey: "debug.softwareDecodeOutputMode")
        defaults.set(false, forKey: "debug.softwareDecodeCompressedOutput")
        defaults.set(2.5, forKey: "debug.regressionRendererRetirementDelaySeconds")

        let tuning = EngineConfiguration.tuning(from: defaults)
        #expect(tuning.stripsDolbyVisionEnhancementLayer)
        #expect(tuning.marksDroppableFrames)
        #expect(tuning.runsFrameLossBench)
        #expect(tuning.tracesDecodeThreads)
        #expect(tuning.profilesAV1Pipeline)
        #expect(tuning.logsPlaybackLifecycle)
        #expect(tuning.hostShowsPlaybackHUD)
        #expect(tuning.buffersOnAudioStarvation)
        #expect(tuning.cachesSegmentedManifests)
        #expect(tuning.softwareDecodeOutputMode == "gpu-sdr-linear")
        // Set-to-false differs from absent, and the engine tells them apart.
        #expect(tuning.softwareDecodeCompressedOutput == false)
        #expect(tuning.rendererRetirementDelaySeconds == 2.5)
    }

    @Test func everyEngineDiagnosticMapsToItsOwnStableCode() {
        // The compiler cannot catch two engine events sharing one app code,
        // which would merge them in every dashboard query.
        let eventCodes = EngineDiagnosticEvent.allCases.map(EngineDiagnosticsBridge.code(for:))
        #expect(Set(eventCodes).count == EngineDiagnosticEvent.allCases.count)

        let incidentCodes = EngineDiagnosticIncident.allCases.map(EngineDiagnosticsBridge.code(for:))
        #expect(Set(incidentCodes).count == EngineDiagnosticIncident.allCases.count)

        #expect(EngineDiagnosticsBridge.code(for: .playbackCacheFallback) == .playbackCacheFallback)
        #expect(EngineDiagnosticsBridge.level(for: .warning) == .warning)
    }
}
