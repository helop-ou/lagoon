import Testing
@testable import Lagoon

/// Lock-screen, Control Center, headset and Siri Remote commands reach the
/// same transport as the player chrome.
@Suite("Now Playing commands")
@MainActor
struct NowPlayingCommandTests {
    @Test func playAndPauseStateTheWantedStateEvenWhenRepeated() {
        let transport = TransportLog()
        for command in [NowPlayingCoordinator.SystemCommand.play, .play, .pause, .pause] {
            NowPlayingCoordinator.route(command, to: transport.actions)
        }
        #expect(transport.calls == ["play", "play", "pause", "pause"])
    }

    @Test func onlyTheToggleCommandToggles() {
        let transport = TransportLog()
        NowPlayingCoordinator.route(.togglePlayPause, to: transport.actions)
        #expect(transport.calls == ["toggle"])
    }

    /// A scrub on the lock screen lands where it was dropped and leaves the
    /// play state alone.
    @Test func skipsAndScrubsSeekWithoutResuming() {
        let transport = TransportLog()
        NowPlayingCoordinator.route(.skip(seconds: -10), to: transport.actions)
        NowPlayingCoordinator.route(.changePosition(seconds: 754.5), to: transport.actions)
        #expect(transport.calls == ["seekBy -10.0", "seek 754.5 resume false"])
    }
}

@MainActor
private final class TransportLog {
    private(set) var calls: [String] = []

    var actions: PlayerTransportActions {
        PlayerTransportActions(
            play: { self.calls.append("play") },
            pause: { self.calls.append("pause") },
            togglePause: { self.calls.append("toggle") },
            seek: { seconds, resume in self.calls.append("seek \(seconds) resume \(resume)") },
            seekBy: { seconds in self.calls.append("seekBy \(seconds)") }
        )
    }
}
