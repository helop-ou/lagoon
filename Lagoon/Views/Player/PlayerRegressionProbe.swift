import Foundation
import SwiftUI

/// Whether the launch-gated player regression probe is on.
///
/// Read once. It is a launch argument, so it cannot change while the app is
/// running, and `videoSurface` used to ask `UserDefaults` for it twice per
/// body evaluation — which, before the player's Observation scope was split
/// up (HEL-150), meant twice per position tick. `CustomPlayerView` is generic
/// over its surface and generics can't hold static storage, so the flag lives
/// here, beside the modifier that reads it.
nonisolated enum PlayerRegressionProbe {
    static let isEnabled = UserDefaults.standard.bool(forKey: "debug.playerRegression")
}

/// A launch-gated accessibility probe for the physical-device UI suite. It
/// observes the same view state the viewer sees; it does not call player
/// actions or replace the Siri Remote interaction path.
///
/// It is a `ViewModifier` rather than a computed string in the player
/// (HEL-150). Almost everything it reports moves at position-tick rate, and
/// a `ViewModifier` has a body of its own, so Observation attaches those
/// reads here instead of to the player's body — and on tvOS to
/// `MenuPressGate`'s hosting update with it. With the flag off the value is
/// never assembled at all, so a shipping build tracks nothing.
///
/// On tvOS the value is deliberately carried by the focusable video surface
/// itself: a separate invisible accessibility element stole arrow focus on
/// the first hardware run and therefore tested the probe, not the player.
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
    /// Where the Up Next card is due, already resolved by the player from
    /// `engine.duration`; only the comparison against the moving position
    /// belongs in here.
    let nextUpCardStart: Double?
    /// Panel open, scrub up, or the card already waved away with Back.
    let isNextUpSuppressed: Bool
    let isScrubbing: Bool
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
        // An external (sidecar) track is the only selection that is not
        // committed synchronously, so it is the only one that can strand the
        // panel on "Loading …". Reported here rather than read off the panel
        // because the panel exists only while it is open, and a stuck load
        // has to be observable after it closes.
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
