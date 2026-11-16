import Foundation
import LagoonEngine
import Testing
@testable import Lagoon

/// The video's own captions join the engine's subtitle list only when the
/// first one is read, so a wanted captions track is picked on arrival.
@Suite("Player closed captions")
@MainActor
struct PlayerClosedCaptionsTests {
    private static let english = PlayerTrack(engineID: 1, kind: .subtitle, displayName: "English", isSelected: false)
    private static let captions = PlayerTrack(
        engineID: PlayerTrack.closedCaptionsEngineID,
        kind: .subtitle,
        displayName: "Closed Captions",
        isSelected: false,
        isHearingImpaired: true
    )

    @Test func wantedCaptionsArePickedOnceWhenTheyTurnUp() {
        let engine = TrackEngine(subtitles: [Self.english])
        let picker = PlayerClosedCaptions()
        picker.attach(engine, wanted: true)

        picker.check()
        #expect(engine.selections.isEmpty)

        engine.subtitleTracks.append(Self.captions)
        picker.check()
        #expect(engine.selections == [PlayerTrack.closedCaptionsEngineID])

        // Turned off afterwards, they stay off.
        engine.select(nil)
        picker.check()
        #expect(engine.selections == [PlayerTrack.closedCaptionsEngineID, nil])
    }

    @Test func captionsAlreadyListedArePickedOnTheFirstCheck() {
        let engine = TrackEngine(subtitles: [Self.captions])
        let picker = PlayerClosedCaptions()
        picker.attach(engine, wanted: true)

        picker.check()
        #expect(engine.selections == [PlayerTrack.closedCaptionsEngineID])
    }

    @Test func unwantedCaptionsAreLeftAlone() {
        let engine = TrackEngine(subtitles: [Self.english, Self.captions])
        let picker = PlayerClosedCaptions()
        picker.attach(engine, wanted: false)

        picker.check()
        #expect(engine.selections.isEmpty)
    }

    /// Whether the viewer picked a track or turned one off, they have
    /// answered before the captions arrived.
    @Test(arguments: [1, nil] as [Int?])
    func aViewerWhoChangedSubtitlesFirstKeepsTheirChoice(choice: Int?) {
        let engine = TrackEngine(subtitles: [Self.english], selected: choice == nil ? 1 : nil)
        let picker = PlayerClosedCaptions()
        picker.attach(engine, wanted: true)
        picker.check()

        engine.select(choice)
        picker.check()
        engine.subtitleTracks.append(Self.captions)
        picker.check()

        #expect(engine.selections == [choice])
    }

    @Test func aNewEngineStartsTheWaitAgain() {
        let first = TrackEngine(subtitles: [Self.captions])
        let second = TrackEngine(subtitles: [Self.captions])
        let picker = PlayerClosedCaptions()
        picker.attach(first, wanted: true)
        picker.check()

        picker.attach(second, wanted: true)
        picker.check()
        #expect(second.selections == [PlayerTrack.closedCaptionsEngineID])
    }

    @Test func theMenuCallsThemClosedCaptionsWithoutAnSDHTag() {
        #expect(Self.captions.subtitleMenuTitle == "Closed Captions")
        let signs = PlayerTrack(
            engineID: 2, kind: .subtitle, displayName: "English", isSelected: false,
            isForced: true, isHearingImpaired: true, source: .external
        )
        #expect(signs.subtitleMenuTitle == "English · External · Forced · SDH")
        let downloaded = PlayerTrack(
            engineID: 3, kind: .subtitle, displayName: "Estonian", isSelected: false, source: .downloaded
        )
        #expect(downloaded.subtitleMenuTitle == "Estonian · Downloaded")
        #expect(Self.english.subtitleMenuTitle == "English")
    }
}

/// Lists subtitle tracks and records every selection it is asked for.
@Observable
private final class TrackEngine: PlayerEngine {
    var timePosition: Double = 0
    var duration: Double = 0
    var isPaused = true
    var isBuffering = false
    var rate: Double = 1
    var stallCount = 0
    var videoSize: CGSize?
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack]
    var currentSubtitleText: String?
    var currentSubtitleImages: [SubtitleImage] = []
    var audioDelay: Double = 0
    var displayMatchRequest: DisplayMatchRequest?
    var selections: [Int?] = []

    init(subtitles: [PlayerTrack], selected: Int? = nil) {
        subtitleTracks = subtitles
        mark(selected)
    }

    func play() {}
    func pause() {}
    func togglePause() {}
    func setRate(_ rate: Double) {}
    func seek(by seconds: Double) {}
    func seek(to seconds: Double) {}
    func selectAudioTrack(id: Int?) {}
    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {}
    func setAudioDelay(_ seconds: Double) {}

    func selectSubtitleTrack(id: Int?) { select(id) }

    func select(_ id: Int?) {
        selections.append(id)
        mark(id)
    }

    private func mark(_ id: Int?) {
        subtitleTracks = subtitleTracks.map { track in
            PlayerTrack(
                engineID: track.engineID,
                kind: track.kind,
                displayName: track.displayName,
                isSelected: track.engineID == id,
                languageTag: track.languageTag,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                source: track.source
            )
        }
    }
}
