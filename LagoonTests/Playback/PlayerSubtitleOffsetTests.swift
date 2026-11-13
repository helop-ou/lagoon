import CoreGraphics
import LagoonEngine
import Observation
import Testing
@testable import Lagoon

/// The panel's subtitle offset reaches the engine that plays and stays with
/// its item, so the next engine for that item starts in step.
@Suite("Player subtitle offset")
@MainActor
struct PlayerSubtitleOffsetTests {
    @Test func aChangeIsKeptAsTheEngineSettledIt() {
        let offset = PlayerSubtitleOffset()
        let engine = BoundedEngine()
        offset.attach(engine, itemID: "offset-settled")
        offset.set(1.5)
        #expect(engine.subtitleOffset == 1.5)
        offset.set(90)
        #expect(engine.subtitleOffset == BoundedEngine.limit)

        // A fallback rung in this player, or the item reopened in another.
        let next = BoundedEngine()
        PlayerSubtitleOffset().attach(next, itemID: "offset-settled")
        #expect(next.offsetsSet == [BoundedEngine.limit])
    }

    @Test func anItemNobodyAdjustedLeavesItsEngineAlone() {
        let offset = PlayerSubtitleOffset()
        let first = BoundedEngine()
        offset.attach(first, itemID: "offset-adjusted")
        offset.set(2)

        let other = BoundedEngine()
        offset.attach(other, itemID: "offset-untouched")
        #expect(other.offsetsSet.isEmpty)

        // The panel now acts on the engine made last.
        offset.set(-1)
        #expect(other.subtitleOffset == -1)
        #expect(first.subtitleOffset == 2)
    }

    @Test func withNoEngineLeftAChangeIsNotKept() {
        let offset = PlayerSubtitleOffset()
        offset.set(2)
        var engine: BoundedEngine? = BoundedEngine()
        offset.attach(engine!, itemID: "offset-gone")
        engine = nil
        offset.set(2)

        let next = BoundedEngine()
        PlayerSubtitleOffset().attach(next, itemID: "offset-gone")
        #expect(next.offsetsSet.isEmpty)
    }

    /// The controller attaches each engine it makes. The panel's closure
    /// then acts on that engine without holding it.
    @Test func theControllerHandsThePanelsChangeToItsEngine() {
        let controller = PlaybackController()
        let engine = BoundedEngine()
        controller.subtitleOffset.attach(engine, itemID: "offset-wiring")
        controller.adjustments.setSubtitleOffset(-0.4)
        #expect(engine.subtitleOffset == -0.4)
    }
}

/// Bounds an offset as the real engine does, and records every one it is set.
@Observable
private final class BoundedEngine: PlayerEngine {
    static let limit = 30.0

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
    var subtitleOffset: Double = 0
    var displayMatchRequest: DisplayMatchRequest?
    var offsetsSet: [Double] = []

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

    func setSubtitleOffset(_ seconds: Double) {
        offsetsSet.append(seconds)
        subtitleOffset = min(max(seconds, -Self.limit), Self.limit)
    }
}
