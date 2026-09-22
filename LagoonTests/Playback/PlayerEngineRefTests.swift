import CoreGraphics
import Observation
import Testing
import LagoonEngine
@testable import Lagoon

/// Player views hold the engine through `PlayerEngineRef`, never strongly:
/// a copied view must not keep a drained engine alive, and once it is gone
/// every read is a no-op.
@Suite("Player engine handle")
@MainActor
struct PlayerEngineRefTests {
    /// A player view holding the wrapper, like `CustomPlayerView`. The backing
    /// storage is private, so the struct answers `isAttached` itself.
    private struct ChromeStandIn {
        @PlayerEngineRef var engine: any PlayerEngine
        var isAttached: Bool { _engine.isAttached }
    }

    // The memberwise initializer still takes the engine directly, which keeps
    // `CustomPlayerView(engine:)` call sites unchanged; the tests below use it.

    @Test func attachedEngineReadsThroughToTheOwner() {
        let engine = TestEngine()
        let standIn = ChromeStandIn(engine: engine)

        #expect(standIn.engine === engine)
        #expect(standIn.isAttached)
    }

    @Test func aCopyKeptPastTheEngineDoesNotLeakIt() {
        weak var probe: TestEngine?
        var standIn: ChromeStandIn
        var copy: ChromeStandIn

        do {
            let engine = TestEngine()
            probe = engine
            standIn = ChromeStandIn(engine: engine)
            copy = standIn // as SwiftUI's gesture-closure context would keep
        }

        #expect(probe == nil)
        #expect(!standIn.isAttached)
        #expect(!copy.isAttached)
        #expect(standIn.engine === DetachedPlayerEngine.shared)
        #expect(copy.engine === DetachedPlayerEngine.shared)
    }

    @Test func detachedEngineReportsNothingPlayingAndIgnoresEveryControl() {
        let engine = DetachedPlayerEngine.shared

        func assertNothingPlaying() {
            #expect(engine.timePosition == 0)
            #expect(engine.duration == 0)
            #expect(engine.isPaused)
            #expect(!engine.isBuffering)
            #expect(engine.audioTracks.isEmpty)
            #expect(engine.subtitleTracks.isEmpty)
            #expect(engine.currentSubtitleText == nil)
            #expect(engine.displayMatchRequest == nil)
        }

        assertNothingPlaying()

        engine.play()
        engine.seek(to: 10)
        engine.togglePause()
        engine.selectSubtitleTrack(id: 1)

        assertNothingPlaying()
    }
}

/// Minimal `PlayerEngine` conformance, shaped like `DetachedPlayerEngine`.
@Observable
private final class TestEngine: PlayerEngine {
    var timePosition: Double = 0
    var duration: Double = 0
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
