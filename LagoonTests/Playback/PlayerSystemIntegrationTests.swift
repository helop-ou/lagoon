import AVFAudio
import AVFoundation
import UIKit
import Foundation
import Testing
@testable import LagoonEngine
@testable import Lagoon

@Suite("Player system integration", .serialized)
struct PlayerSystemIntegrationTests {
    @Test func privateRouteLossPausesButHDMIDisplayChangeDoesNot() {
        #expect(PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .oldDeviceUnavailable,
            previousOutputs: [.headphones]
        ))
        #expect(PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .oldDeviceUnavailable,
            previousOutputs: [.bluetoothA2DP]
        ))
        #expect(!PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .oldDeviceUnavailable,
            previousOutputs: [.HDMI]
        ))
        #expect(!PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .newDeviceAvailable,
            previousOutputs: [.headphones]
        ))
    }

    /// Picture in picture stopping while the app is away leaves nothing to
    /// show video, so it is suspended as backgrounding would.
    @Test func videoIsSuspendedOnlyWhenNothingShowsIt() {
        #expect(PlaybackController.videoIsUnseen(inBackground: true, pictureInPicture: false, airPlay: false))
        #expect(!PlaybackController.videoIsUnseen(inBackground: true, pictureInPicture: true, airPlay: false))
        #expect(!PlaybackController.videoIsUnseen(inBackground: true, pictureInPicture: false, airPlay: true))
        // On screen, picture in picture stopping changes nothing.
        #expect(!PlaybackController.videoIsUnseen(inBackground: false, pictureInPicture: false, airPlay: false))
    }

}
