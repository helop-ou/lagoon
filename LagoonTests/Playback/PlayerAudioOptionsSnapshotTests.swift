import LagoonEngine
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The player panel's audio tab: the tracks and the options beside them.
@Suite("Player audio options snapshots", .serialized)
@MainActor
struct PlayerAudioOptionsSnapshotTests {
    @Test func syncAdjustmentsAndSoundToggles() async throws {
        try await Snapshot.verify(
            AudioTab(subtitleOffset: 1.5, audioShaping: AudioShaping(nightMode: true)),
            named: "audio-options",
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

    private struct AudioTab: View {
        @FocusState private var focus: PlayerControlFocus?
        @State private var tab = PlayerPanelTab.audio
        let subtitleOffset: Double
        let audioShaping: AudioShaping

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
                    PlayerTrack(engineID: 2, kind: .audio, displayName: "Commentary · Stereo · AAC", isSelected: false),
                ],
                subtitleTracks: [
                    PlayerTrack(engineID: 1, kind: .subtitle, displayName: "English", isSelected: true),
                ],
                audioDelay: 0,
                subtitleOffset: subtitleOffset,
                audioShaping: audioShaping,
                playbackRate: 1,
                onSelectAudioTrack: { _ in },
                onSelectSubtitleTrack: { _ in },
                onSetAudioDelay: { _ in },
                onSetSubtitleOffset: { _ in },
                onSetNightMode: { _ in },
                onSetDialogueBoost: { _ in },
                onSetPlaybackRate: { _ in }
            )
        }
    }
}
