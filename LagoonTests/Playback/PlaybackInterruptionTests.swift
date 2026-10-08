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
}
