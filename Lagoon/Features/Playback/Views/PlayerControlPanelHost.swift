import LagoonEngine
import SwiftUI

/// Observation boundary between the playback clock and the panel. Observes
/// only what the panel shows; `Equatable` stops parent updates walking the
/// tabs and rows. Keep both.
struct PlayerControlPanelHost: View, Equatable {
    @PlayerEngineRef var engine: any PlayerEngine
    @Binding var selectedTab: PlayerPanelTab
    let focus: FocusState<PlayerControlFocus?>.Binding
    let info: PlayerItemInfo
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    var together: PlayerTogetherState? = nil
    var onLeaveGroup: (() -> Void)? = nil
    var onSetIgnoreWait: ((Bool) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine === rhs.engine
            && lhs.info == rhs.info
            && lhs.subtitleSearch === rhs.subtitleSearch
            && lhs.isPictureInPicturePossible == rhs.isPictureInPicturePossible
            && lhs.isPictureInPictureActive == rhs.isPictureInPictureActive
            && lhs.together == rhs.together
    }

    var body: some View {
        PlayerControlPanel(
            selectedTab: $selectedTab,
            focus: focus,
            info: info,
            audioTracks: engine.audioTracks,
            subtitleTracks: engine.subtitleTracks,
            audioDelay: engine.audioDelay,
            playbackRate: engine.rate,
            subtitleSearch: subtitleSearch,
            subtitleLoadState: engine.subtitleLoadState,
            onRetrySubtitleLoad: { engine.retrySubtitleLoad() },
            isPictureInPicturePossible: isPictureInPicturePossible,
            isPictureInPictureActive: isPictureInPictureActive,
            onTogglePictureInPicture: onTogglePictureInPicture,
            together: together,
            onLeaveGroup: onLeaveGroup,
            onSetIgnoreWait: onSetIgnoreWait,
            onSelectAudioTrack: { engine.selectAudioTrack(id: $0) },
            onSelectSubtitleTrack: { id in
                subtitleSearch?.cancelDownload()
                engine.selectSubtitleTrack(id: id)
            },
            onSetAudioDelay: { engine.setAudioDelay($0) },
            onSetPlaybackRate: { engine.setRate($0) },
            onDismiss: onDismiss
        )
    }
}
