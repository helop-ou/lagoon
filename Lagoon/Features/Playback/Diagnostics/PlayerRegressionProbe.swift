import Foundation
import LagoonEngine
import SwiftUI

/// Whether the launch-gated player regression probe is on. Read once: it is
/// a launch argument, and `CustomPlayerView` is generic so cannot hold
/// static storage.
nonisolated enum PlayerRegressionProbe {
    static let isEnabled = UserDefaults.standard.bool(forKey: "debug.playerRegression")
}

/// A launch-gated accessibility probe for the physical-device UI suite. It
/// observes what the viewer sees; it never calls player actions or replaces
/// the Siri Remote path.
///
/// A `ViewModifier` so its tick-rate reads land in its own body, not the
/// player's. With the flag off nothing is assembled.
///
/// On tvOS the value rides on the focusable video surface: a separate
/// invisible element stole arrow focus.
struct PlayerRegressionValue: ViewModifier {
    @PlayerEngineRef var engine: any PlayerEngine
    let info: PlayerItemInfo
    let playbackIdentity: String
    let playerSurfaceIdentity: String
    let playbackMethod: PlayMethod
    let deliveryRung: PlaybackDelivery
    let isPlaybackCacheActive: Bool
    let bufferedFraction: Double?
    let bufferedRanges: [PlaybackBufferedRange]
    let playheadPrefetchCount: Int
    let handoffMilliseconds: Double?
    /// Where the Up Next card is due, already resolved from `engine.duration`.
    let nextUpCardStart: Double?
    let isNextUpSuppressed: Bool
    let isScrubbing: Bool
    let isTransportVisible: Bool
    let lastCommittedScrubTarget: Double
    let panelOpen: Bool
    let selectedTab: PlayerPanelTab
    let focus: PlayerControlFocus?
    let trickplay: TrickplayLoader?

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .accessibilityIdentifier(PlayerRegressionProbe.isEnabled ? "player.regression.state" : "")
            .accessibilityValue(PlayerRegressionProbe.isEnabled ? value : "")
        #elseif DEBUG
        content
            .overlay(alignment: .topLeading) {
                if PlayerRegressionProbe.isEnabled {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Playback state")
                        .accessibilityIdentifier("player.regression.state")
                        .accessibilityValue(value)
                }
            }
        #else
        content
        #endif
    }

    private var showsNextUp: Bool {
        guard let nextUpCardStart, !isNextUpSuppressed else { return false }
        return engine.timePosition >= nextUpCardStart
    }

    private var value: String {
        let selectedAudio = engine.audioTracks.first(where: \.isSelected)?.engineID ?? 0
        let selectedSubtitle = engine.subtitleTracks.first(where: \.isSelected)?.engineID ?? 0
        // An external sidecar track is the only selection that can strand the
        // panel on "Loading …". Reported here because the panel is gone after it
        // closes.
        let subtitleLoad: String = switch engine.subtitleLoadState {
        case .idle: "idle"
        case .loading(let id, _): "loading-\(id)"
        case .failed(let id, _, _): "failed-\(id)"
        }
        let skippable = info.segments.first(where: { $0.kind.isSkippable })
        let skippableStart: Double = skippable?.start ?? -1
        let skippableEnd: Double = skippable?.end ?? -1
        let focusDescription: String = switch focus {
        case .surface: "surface"
        case .tab(let tab): "tab-\(String(describing: tab))"
        case .track(let id): "track-\(id)"
        case nil: "none"
        }
        let memory = MemorySnapshot.current()
        let lifecycle = PlaybackLifecycleDiagnostics.snapshot()
        var elements: [String] = [
            "item=\(playbackIdentity)",
            "surface=\(playerSurfaceIdentity)",
            "method=\(playbackMethod.rawValue)",
            "rung=\(deliveryRung.rawValue)",
            "cache=\(isPlaybackCacheActive ? 1 : 0)",
            String(format: "buffered=%.3f", bufferedFraction ?? -1),
            "bufferRanges=\(bufferedRanges.count)",
            "playheadPrefetches=\(playheadPrefetchCount)",
            String(format: "handoffMs=%.1f", handoffMilliseconds ?? -1),
            "nextUp=\(showsNextUp ? 1 : 0)",
            "ready=\(engine.duration > 0 ? 1 : 0)",
            String(format: "time=%.1f", engine.timePosition),
            String(format: "duration=%.1f", engine.duration),
            "paused=\(engine.isPaused ? 1 : 0)",
            "buffering=\(engine.isBuffering ? 1 : 0)",
            "stalls=\(engine.stallCount)",
            "aDry=\(engine.audioStarvationCount)",
            "audioStalls=\(engine.audioStallCount)",
            "audioBuffers=\(engine.buffersOnAudioStarvation ? 1 : 0)",
            String(format: "audioLead=%.3f", engine.audioDeliveryLeadSeconds),
            "audioReady=\(engine.audioRendererReadyForPlayback ? 1 : 0)",
            "videoQueued=\(engine.videoQueueCountDiagnostic)",
            "videoMax=\(engine.maximumVideoBacklogDiagnostic)",
            "videoHard=\(engine.videoQueueHardLimitDiagnostic)",
            "videoIntake=\(engine.videoIntakeCountDiagnostic)",
            "videoIntakeMax=\(engine.maximumVideoIntakeDiagnostic)",
            "reprimes=\(engine.stallReprimeCount)",
            "idleRequests=\(engine.idleRequestCallbacks)",
            "audioRecoveries=\(engine.audioRendererRecoveryCount)",
            "mediaResetRecoveries=\(engine.mediaServicesResetRecoveryCount)",
            String(format: "memoryMB=%.1f", memory.footprintMB),
            "engines=\(lifecycle.liveEngines)",
            "controllers=\(lifecycle.liveControllers)",
            "demux=\(lifecycle.activeDemuxLoops)",
            "renderers=\(lifecycle.attachedRendererSets)",
            "unclean=\(lifecycle.uncleanEngineDestructions)",
            "scrubbing=\(isScrubbing ? 1 : 0)",
            "transport=\(isTransportVisible ? 1 : 0)",
            String(format: "lastScrub=%.1f", lastCommittedScrubTarget),
            "panel=\(panelOpen ? 1 : 0)",
            "tab=\(String(describing: selectedTab))",
            "focus=\(focusDescription)",
            String(format: "rate=%g", engine.rate),
            "audio=\(selectedAudio)",
            "audioPath=\(engine.audioOutputPathDiagnostic)",
            "videoPath=\(engine.videoOutputPathDiagnostic)",
            "audioCount=\(engine.audioTracks.count)",
            "subtitle=\(selectedSubtitle)",
            "subtitleCount=\(engine.subtitleTracks.count)",
            "subtitleLoad=\(subtitleLoad)",
            "subtitleVisible=\((engine.currentSubtitleText != nil || !engine.currentSubtitleImages.isEmpty) ? 1 : 0)",
            "chapters=\(info.chapters.count)",
            "trickplay=\(info.trickplay == nil ? 0 : 1)",
            "trickplayFrame=\(trickplay?.frame == nil ? 0 : 1)",
            "segments=\(info.segments.count)",
            String(format: "skippableStart=%.1f", skippableStart),
            String(format: "skippableEnd=%.1f", skippableEnd),
        ]
        #if DEBUG
        elements.append(contentsOf: [
            "audioHeld=\(engine.audioDeliverySuspendedForDiagnostics ? 1 : 0)",
            "deliveryHeld=\(engine.demuxDeliverySuspendedForDiagnostics ? 1 : 0)",
        ])
        #endif
        return elements.joined(separator: " ")
    }
}
