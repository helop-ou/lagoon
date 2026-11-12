import LagoonEngine
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The player's own buttons: the iOS centre cluster over a picture and
/// Episodes list, and the tvOS row with its Sound and Episodes lists.
@Suite("Player button snapshots", .serialized)
@MainActor
struct PlayerButtonSnapshotTests {
    /// A season of five with the second playing.
    private static func season() throws -> PlayerEpisodeList {
        let names = ["Life and Death", "Five Minutes", "In the Line of Fire", "Red Hot", "A.C.H."]
        let episodes = try names.enumerated().map { index, name in
            try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"""
            {"Id":"e\#(index + 1)","Name":"\#(name)","Type":"Episode","SeriesId":"s","SeriesName":"The Rookie",\#
            "SeasonId":"s4","ParentIndexNumber":4,"IndexNumber":\#(index + 1)}
            """#.utf8))
        }
        return try #require(PlayerEpisodeList.season(episodes, current: episodes[1]))
    }

    #if os(iOS)
    private static let clusterSize = CGSize(width: 402, height: 160)
    private static let listSize = CGSize(width: 402, height: 520)

    @Test func theEpisodesList() async throws {
        try await Snapshot.verify(
            PlayerEpisodeListSheet(list: try Self.season(), onSelect: { _ in }),
            named: "episodes-list",
            size: Self.listSize
        )
    }

    private func cluster(_ episodes: PlayerEpisodeButtons?) -> some View {
        PlayerTouchTransportCluster(
            engine: DetachedPlayerEngine.shared,
            onSkip: { _ in },
            onTogglePlayPause: {},
            episodes: episodes
        )
    }

    /// Over a flat picture: clear glass refracts artwork a little
    /// differently from one render to the next.
    private func overFlatVideo(_ content: some View) -> some View {
        ZStack {
            Color(white: 0.3)
            content
        }
        .frame(width: Self.clusterSize.width, height: Self.clusterSize.height)
    }

    @Test func theClusterWithBothNeighbours() async throws {
        try await Snapshot.verify(
            overFlatVideo(cluster(PlayerEpisodeButtons(hasPrevious: true, hasNext: true))),
            named: "cluster-both",
            size: Self.clusterSize
        )
    }

    /// The first episode keeps the previous slot, so play/pause stays put.
    @Test func theClusterWithOnlyANextTitle() async throws {
        try await Snapshot.verify(
            overFlatVideo(cluster(PlayerEpisodeButtons(hasPrevious: false, hasNext: true))),
            named: "cluster-next-only",
            size: Self.clusterSize
        )
    }
    #endif

    #if os(tvOS)
    /// Little wider than the row, so one changed symbol is over the tolerance.
    private static let rowSize = CGSize(width: 640, height: 200)

    /// The row with every button. Episodes and Sound are UIKit buttons
    /// whose system menus cannot be rendered here.
    private struct Row: View {
        @FocusState private var focus: PlayerControlFocus?
        @State private var menus = PlayerRowMenus()
        let episodes: PlayerEpisodeList

        var body: some View {
            PlayerTVControlRow(
                episodes: PlayerEpisodeButtons(hasPrevious: true, hasNext: true),
                episodeList: episodes,
                soundOptions: PlayerSoundOptions(
                    shaping: AudioShaping(nightMode: true, dialogueBoost: false, channelLimit: .stereo),
                    setNightMode: { _ in },
                    setDialogueBoost: { _ in },
                    setChannelLimit: { _ in }
                ),
                pictureInPicture: .start,
                focus: $focus,
                menus: menus,
                onPrevious: {},
                onPlayEpisode: { _ in },
                onTogglePictureInPicture: {},
                onNext: {},
                onMoveDown: {}
            )
            .padding(Metrics.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    /// Over black: glass adapts to a lighter picture across the first
    /// frames, the UIKit buttons sooner than the SwiftUI ones under load.
    @Test func theRowAboveTheScrubber() async throws {
        try await Snapshot.verify(
            Row(episodes: try Self.season()).frame(width: Self.rowSize.width, height: Self.rowSize.height),
            named: "tv-row",
            size: Self.rowSize
        )
    }
    #endif
}
