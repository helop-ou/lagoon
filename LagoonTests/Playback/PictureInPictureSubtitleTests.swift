import AVFoundation
import AVKit
import LagoonEngine
import Observation
import SwiftUI
import Testing
@testable import Lagoon

/// The engine draws subtitles into the frames while Picture in Picture
/// shows, where the player's own overlay is gone, and only then.
@Suite("Picture in Picture subtitles", .serialized)
@MainActor
struct PictureInPictureSubtitleTests {
    @Test func theEngineDrawsSubtitlesOnlyWhileTheWindowShows() throws {
        let (pictureInPicture, controller, engine) = try Self.attached()
        #expect(engine.pictureInPictureStyles.isEmpty, "nothing before the window opens")

        pictureInPicture.pictureInPictureControllerDidStartPictureInPicture(controller)
        #expect(engine.pictureInPictureStyles == [Self.style])
        pictureInPicture.pictureInPictureControllerDidStopPictureInPicture(controller)
        #expect(engine.pictureInPictureStyles == [Self.style, nil])
    }

    /// The next episode takes over inside the window: the outgoing engine
    /// stops drawing and the incoming one starts.
    @Test func aHandoffInsideTheWindowMovesTheSubtitlesToTheNewEngine() throws {
        let (pictureInPicture, controller, outgoing) = try Self.attached()
        pictureInPicture.pictureInPictureControllerDidStartPictureInPicture(controller)
        let incoming = RecordingEngine()
        pictureInPicture.handOff(to: incoming)
        #expect(outgoing.pictureInPictureStyles.last == .some(nil))
        #expect(incoming.pictureInPictureStyles == [Self.style])
    }

    @Test func closingThePlayerStopsTheDrawing() throws {
        let (pictureInPicture, controller, engine) = try Self.attached()
        pictureInPicture.pictureInPictureControllerDidStartPictureInPicture(controller)
        pictureInPicture.reset()
        #expect(engine.pictureInPictureStyles.last == .some(nil))
    }

    @Test func theViewersSettingsBecomeTheEnginesStyle() {
        let style = SubtitlePreferencesStore.burnedInStyle(
            text: CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1),
            background: CGColor(gray: 0, alpha: 1),
            backgroundOpacity: 0.5,
            edge: .outline,
            scale: 1.5,
            fontName: "Avenir-Medium"
        )
        #expect(style.textColor == SubtitleTextColor(red: 255, green: 255, blue: 0, alpha: 255))
        #expect(style.backgroundColor == SubtitleTextColor(red: 0, green: 0, blue: 0, alpha: 128))
        #expect(style.edge == .outline)
        #expect(abs(style.relativeSize - SubtitlePreferencesStore.burnedInRelativeSize * 1.5) < 0.0001)
        #expect(style.fontName == "Avenir-Medium")
        #expect(SubtitlePreferencesStore.burnedInStyle(
            text: CGColor(gray: 1, alpha: 1), background: CGColor(gray: 0, alpha: 1),
            backgroundOpacity: 0, edge: .shadow, scale: 1, fontName: nil
        ).edge == .dropShadow)
    }

    /// The default caption style names the system font ".SFUI-Medium", and an
    /// iPhone drew picture in picture subtitles in Times.
    @Test func aSystemFontNameLeavesTheFontToTheEngine() {
        let style = SubtitlePreferencesStore.burnedInStyle(
            text: CGColor(gray: 1, alpha: 1), background: CGColor(gray: 0, alpha: 1),
            backgroundOpacity: 0, edge: .shadow, scale: 1, fontName: ".SFUI-Medium"
        )
        #expect(style.fontName == nil)
    }

    // MARK: - Helpers

    private static let style = BurnedInSubtitleStyle(relativeSize: 0.07)

    private static func attached() throws -> (SampleBufferPictureInPicture, AVPictureInPictureController, RecordingEngine) {
        let pictureInPicture = SampleBufferPictureInPicture()
        pictureInPicture.subtitleStyle = { style }
        let engine = RecordingEngine()
        let layer = AVSampleBufferDisplayLayer()
        pictureInPicture.attach(displayLayer: layer, engine: engine)
        let controller = AVPictureInPictureController(contentSource: .init(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: pictureInPicture
        ))
        return (pictureInPicture, controller, engine)
    }
}

/// Records what Picture in Picture asks of the engine.
@Observable
private final class RecordingEngine: PlayerEngine {
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
    var pictureInPictureStyles: [BurnedInSubtitleStyle?] = []

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
    func setSubtitleOffset(_ seconds: Double) {}
    func setPictureInPictureSubtitles(_ style: BurnedInSubtitleStyle?) {
        pictureInPictureStyles.append(style)
    }
}
