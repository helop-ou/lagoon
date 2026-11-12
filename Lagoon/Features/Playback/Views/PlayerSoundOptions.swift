import LagoonEngine
import SwiftUI

/// Night Mode, Dialogue Boost and the channel limit, from the player's own
/// sound button. A value with its actions, so the iOS and tvOS menus apply a
/// change the same way.
struct PlayerSoundOptions {
    let shaping: AudioShaping
    let setNightMode: (Bool) -> Void
    let setDialogueBoost: (Bool) -> Void
    let setChannelLimit: (AudioChannelLimit) -> Void

    var channelLimit: AudioChannelLimit { AudioChannelLimit(engineLimit: shaping.channelLimit) }

    /// A waveform, not a speaker: the button shapes the sound, while a
    /// speaker reads as volume or the output route.
    static let systemImage = "waveform"
    static let menuID = "sound"
}


#if os(tvOS)
/// The tvOS buttons above the scrubber: previous, Episodes, Sound, Picture in
/// Picture and next, each only where it has something to do. Focus comes
/// here with Up from the surface while the transport is up, and Down sends
/// it back, so the surface keeps the arrows for scrubbing. Episodes and
/// Sound are UIKit buttons with system menus (`PlayerRowMenuButton`).
///
/// Equatable on what it shows, so the transport's own updates leave the
/// menus alone.
struct PlayerTVControlRow: View, Equatable {
    let episodes: PlayerEpisodeButtons?
    let episodeList: PlayerEpisodeList?
    let soundOptions: PlayerSoundOptions
    let pictureInPicture: PlayerPictureInPictureButton?
    let focus: FocusState<PlayerControlFocus?>.Binding
    let menus: PlayerRowMenus
    let onPrevious: () -> Void
    let onPlayEpisode: (PlayerEpisodeList.Row) -> Void
    let onTogglePictureInPicture: () -> Void
    let onNext: () -> Void
    let onMoveDown: () -> Void

    static let previousID = "previous"
    static let episodesID = "episodes"
    static let soundID = "sound"
    static let pictureInPictureID = "picture-in-picture"
    static let nextID = "next"

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episodes == rhs.episodes
            && lhs.episodeList == rhs.episodeList
            && lhs.soundOptions.shaping == rhs.soundOptions.shaping
            && lhs.pictureInPicture == rhs.pictureInPicture
    }

    var body: some View {
        HStack(spacing: Metrics.Space.l) {
            if episodes?.hasPrevious == true {
                // Outline, like the rest of the row's symbols.
                Button("Previous", systemImage: "backward.end", action: onPrevious)
                    .focused(focus, equals: .control(Self.previousID))
                    .accessibilityIdentifier("player.previous")
            }
            if let episodeList {
                PlayerRowMenuButton(
                    id: Self.episodesID,
                    title: String(localized: "Episodes"),
                    systemImage: "list.and.film",
                    accessibilityIdentifier: "player.episodes",
                    menuKey: PlayerRowMenuContent.episodeMenuKey(episodeList),
                    menus: menus,
                    makeMenu: { PlayerRowMenuContent.episodeMenu(episodeList, onPlay: onPlayEpisode) },
                    onMoveDown: onMoveDown
                )
                .frame(width: RowMetrics.menuButton, height: RowMetrics.menuButton)
            }
            PlayerRowMenuButton(
                id: Self.soundID,
                title: String(localized: "Sound"),
                systemImage: PlayerSoundOptions.systemImage,
                accessibilityIdentifier: "player.sound",
                menuKey: PlayerRowMenuContent.soundMenuKey(soundOptions),
                menus: menus,
                makeMenu: { PlayerRowMenuContent.soundMenu(soundOptions) },
                onMoveDown: onMoveDown
            )
            .frame(width: RowMetrics.menuButton, height: RowMetrics.menuButton)
            if let pictureInPicture {
                Button(pictureInPicture.title, systemImage: pictureInPicture.systemImage, action: onTogglePictureInPicture)
                    .focused(focus, equals: .control(Self.pictureInPictureID))
                    .accessibilityIdentifier("player.pictureInPicture")
            }
            if episodes?.hasNext == true {
                Button("Next", systemImage: "forward.end", action: onNext)
                    .focused(focus, equals: .control(Self.nextID))
                    .accessibilityIdentifier("player.next")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .focusSection()
    }

    private enum RowMetrics {
        /// The glass circle of the row's SwiftUI buttons, which UIKit's
        /// glass configuration does not size by itself.
        static let menuButton: CGFloat = 66
    }
}
#endif
