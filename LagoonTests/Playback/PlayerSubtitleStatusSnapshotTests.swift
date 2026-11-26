import LagoonEngine
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The player panel's subtitles tab, with the line under Find Subtitles that
/// says how a download ended.
@Suite("Player subtitle status snapshots", .serialized)
@MainActor
struct PlayerSubtitleStatusSnapshotTests {
    @Test func aSubtitleTheServerCouldNotSave() async throws {
        try await Snapshot.verify(
            SubtitlesTab(search: .previewing(.downloadedButNotSaved)),
            named: "subtitle-not-saved",
            size: Self.size
        )
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 1920, height: 1080)
        #else
        CGSize(width: 402, height: 874)
        #endif
    }

    private struct SubtitlesTab: View {
        @FocusState private var focus: PlayerControlFocus?
        @State private var tab = PlayerPanelTab.subtitles
        let search: SubtitleSearchCoordinator

        var body: some View {
            PlayerControlPanel(
                selectedTab: $tab,
                focus: $focus,
                info: PlayerItemInfo(
                    title: "Pilot",
                    subtitle: nil,
                    overview: nil,
                    facts: [],
                    videoSummary: nil,
                    posterURL: nil,
                    chapters: []
                ),
                audioTracks: [
                    PlayerTrack(engineID: 1, kind: .audio, displayName: "English · 5.1 · E-AC3", isSelected: true),
                ],
                subtitleTracks: [
                    PlayerTrack(
                        engineID: 1, kind: .subtitle, displayName: "English", isSelected: true, source: .downloaded
                    ),
                ],
                audioDelay: 0,
                subtitleOffset: 0,
                playbackRate: 1,
                subtitleSearch: search,
                onSelectAudioTrack: { _ in },
                onSelectSubtitleTrack: { _ in },
                onSetAudioDelay: { _ in },
                onSetSubtitleOffset: { _ in },
                onSetPlaybackRate: { _ in }
            )
        }
    }
}
