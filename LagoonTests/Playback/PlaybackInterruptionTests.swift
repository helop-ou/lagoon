import AVFAudio
import Testing
@testable import Lagoon

/// A call or another app's audio ends: playback comes back only if the
/// interruption is what stopped it.
@Suite("Playback audio interruption")
struct PlaybackInterruptionTests {
    @Test func playbackTheInterruptionPausedResumesWhenTheSystemSaysSo() {
        #expect(PlaybackAudioSession.shouldResume(wasPlaying: true, options: .shouldResume))
    }

    @Test func theSystemCanKeepItPaused() {
        #expect(!PlaybackAudioSession.shouldResume(wasPlaying: true, options: []))
    }

    /// The viewer had already paused, so the end of a call must not start it.
    @Test func playbackPausedBeforehandStaysPaused() {
        #expect(!PlaybackAudioSession.shouldResume(wasPlaying: false, options: .shouldResume))
        #expect(!PlaybackAudioSession.shouldResume(wasPlaying: false, options: []))
    }

    /// A report says what kind of output a route change left and reached,
    /// which tells an HDMI link dropping from earphones being taken out.
    @Test func aRouteIsReportedByTheKindOfItsOutputs() {
        #expect(PlaybackAudioSession.outputKinds([.HDMI]) == "hdmi")
        #expect(PlaybackAudioSession.outputKinds([]) == "none")
        #expect(PlaybackAudioSession.outputKinds([.bluetoothA2DP, .bluetoothLE]) == "bluetooth")
        #expect(PlaybackAudioSession.outputKinds([.headphones, .airPlay]) == "airPlay,headphones")
        #expect(PlaybackAudioSession.outputKinds([.builtInSpeaker]) == "speaker")
        #expect(PlaybackAudioSession.outputKinds([.usbAudio]) == "other")
    }

    /// A port's name is the name of someone's device, and often their own.
    /// Only the kind is read, and the schema lets nothing else out.
    @Test func aRouteNeverNamesADevice() {
        let named = AVAudioSession.Port(rawValue: "Sams-AirPods-Pro")
        #expect(PlaybackAudioSession.outputKinds([named]) == "other")
        for ports in [[AVAudioSession.Port.HDMI], [.airPlay, .builtInSpeaker], [named], []] {
            let kinds = PlaybackAudioSession.outputKinds(ports)
            #expect(DiagnosticSchema.validated(["routeFrom": .string(kinds), "routeTo": .string(kinds)]).rejected == 0)
        }
        #expect(DiagnosticSchema.validated(["routeTo": .string("Sams-AirPods-Pro")]).rejected == 1)
        #expect(DiagnosticSchema.validated(["routeFrom": .string("Living Room")]).rejected == 1)
    }
}
