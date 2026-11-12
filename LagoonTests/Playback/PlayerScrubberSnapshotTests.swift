import LagoonEngine
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The scrubber reads the buffered ranges from the engine itself. Passed down
/// from the player instead, they redrew the whole player several times a
/// second while it played.
@Suite("Scrubber snapshots", .serialized)
@MainActor
struct PlayerScrubberSnapshotTests {
    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 1200, height: 80)
        #else
        CGSize(width: 600, height: 120)
        #endif
    }

    @Test func theScrubberDrawsTheEnginesBufferedRanges() async throws {
        let engine = BufferedEngine()
        engine.bufferState = PlaybackBufferState(
            isActive: true,
            bufferedFraction: 0.62,
            bufferedRanges: [
                PlaybackBufferedRange(lowerFraction: 0, upperFraction: 0.18),
                PlaybackBufferedRange(lowerFraction: 0.29, upperFraction: 0.62),
            ]
        )
        try await Snapshot.verify(
            PlayerScrubber(
                engine: engine,
                isVisible: true,
                chapters: [],
                trickplaySource: nil,
                scrubTarget: nil,
                trickplay: nil
            )
            .padding(Metrics.Space.l)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(white: 0.3)),
            named: "scrubber-buffered",
            size: Self.size
        )
    }
}

@Observable
private final class BufferedEngine: PlayerEngine {
    var bufferState = PlaybackBufferState.empty
    var timePosition: Double = 120
    var duration: Double = 1_000
    var isPaused = true
    var isBuffering = false
    var rate: Double = 1
    var stallCount = 0
    var videoSize: CGSize?
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    var currentSubtitleText: String?
    var currentSubtitleImages: [SubtitleImage] = []
    var audioDelay: Double = 0
    var displayMatchRequest: DisplayMatchRequest?

    func play() {}
    func pause() {}
    func togglePause() {}
    func setRate(_ rate: Double) {}
    func seek(by seconds: Double) {}
    func seek(to seconds: Double) {}
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {}
    func setAudioDelay(_ seconds: Double) {}
}
