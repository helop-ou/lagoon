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

    @Test @MainActor func systemCommandsUseIdempotentPlaybackState() {
        let engine = SampleBufferPlayerEngine()
        engine.pause()
        engine.pause()
        #expect(engine.isPaused)
        engine.play()
        engine.play()
        #expect(!engine.isPaused)
    }

    @Test @MainActor func playbackRateSurvivesPauseAndIsBounded() {
        let engine = SampleBufferPlayerEngine()
        engine.setRate(1.5)
        #expect(engine.rate == 1.5)
        engine.pause()
        engine.play()
        #expect(engine.rate == 1.5)
        engine.setRate(99)
        #expect(engine.rate == PlaybackRatePolicy.maximum)
        engine.setRate(.nan)
        #expect(engine.rate == 1)
    }

    @Test func playbackRateStepsAndRendersFromOnePlace() {
        // The panel, the title readout and the UI tests all read these.
        #expect(PlaybackRatePolicy.title(1) == "1×")
        #expect(PlaybackRatePolicy.title(1.25) == "1.25×")
        #expect(PlaybackRatePolicy.title(0.5) == "0.5×")
        // Remote Command Center can send a rate outside the set; it renders clamped.
        #expect(PlaybackRatePolicy.title(99) == "2×")

        // Stepping clamps, never wraps.
        #expect(PlaybackRatePolicy.stepped(from: 1, by: 1) == 1.25)
        #expect(PlaybackRatePolicy.stepped(from: 1, by: -1) == 0.75)
        #expect(PlaybackRatePolicy.stepped(from: 2, by: 1) == 2)
        #expect(PlaybackRatePolicy.stepped(from: 0.5, by: -1) == 0.5)
        // A value the engine accepts but the set does not contain still steps.
        #expect(PlaybackRatePolicy.stepped(from: 1.1, by: 1) == 1.25)
        #expect(PlaybackRatePolicy.stepped(from: 1.1, by: -1) == 1)

        #expect(PlaybackRatePolicy.identifier(1) == "1")
        #expect(PlaybackRatePolicy.identifier(1.25) == "1_25")
        #expect(PlaybackRatePolicy.identifier(0.75) == "0_75")
    }

    @Test func aSyncCorrectionRidesOnTheViewersRateWithoutLeavingTheEnvelope() {
        // A group nudge multiplies the viewer's rate; no correction leaves it alone.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1, correction: 1) == 1)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.5, correction: 1) == 1.5)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1, correction: 1.05) == 1.05)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 2, correction: 0.5) == 1)

        // The product stays inside the engine's rate envelope.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 2, correction: 4) == PlaybackRatePolicy.maximum)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 0.5, correction: 0.1) == PlaybackRatePolicy.minimum)
        // The viewer's rate is clamped before the correction applies.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 99, correction: 0.5) == 1)

        // A nonsense multiplier is ignored; stopping is `pause`, never a zero correction.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: 0) == 1.25)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: -1) == 1.25)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: .nan) == 1.25)
    }

    @Test @MainActor func aCorrectionRateLeavesTheViewersChosenRateAlone() {
        // The speed row and Now Playing show `rate`, so a nudge must not move it.
        let engine = SampleBufferPlayerEngine()
        engine.setRate(1.25)
        engine.setCorrectionRate(1.05)
        #expect(engine.rate == 1.25)
        #expect(engine.correctionRate == 1.05)
        engine.setCorrectionRate(1)
        #expect(engine.rate == 1.25)
        #expect(engine.correctionRate == 1)
    }

    @Test func stallRecoveryKeepsItsWallClockCushionAtFasterRates() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 12,
            videoQueueFinished: false,
            playbackRate: 1.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 18,
            videoQueueFinished: false,
            playbackRate: 1.5
        ) == .resume)
    }

    @Test @MainActor func everyAudioRendererSpatializesStereoTheWayAVPlayerDoes() {
        // `AVSampleBufferAudioRenderer` defaults to `multichannel` only, unlike
        // `AVPlayerItem`. The first check fails if a future SDK changes that.
        #expect(AVSampleBufferAudioRenderer().allowedAudioSpatializationFormats == .multichannel)
        #expect(
            SampleBufferPlayerEngine.makeAudioRenderer().allowedAudioSpatializationFormats
                == .monoStereoAndMultichannel
        )
        #expect(SampleBufferPlayerEngine.makeAudioRenderer().audioTimePitchAlgorithm == .timeDomain)
    }

    @Test @MainActor func aShutDownEngineCannotBeBroughtBackToLife() async {
        // SwiftUI re-mounts the player surface after a failure and `makeUIView`
        // attaches unconditionally. A shut-down engine must ignore it, or it
        // registers renderers that never detach and reopens the stream.
        let before = PlaybackLifecycleDiagnostics.snapshot()
        let engine = SampleBufferPlayerEngine()
        engine.prepare(
            url: URL(string: "https://media.test/never-opened.mkv")!,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        engine.shutdown()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())

        // Nothing registered, so nothing waits on an AVFoundation completion.
        let after = PlaybackLifecycleDiagnostics.snapshot()
        #expect(after.attachedRendererSets == before.attachedRendererSets)
        #expect(after.activeDemuxLoops == before.activeDemuxLoops)
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(5)))
    }

    @Test func onlyAMediaServicesResetLeavesThePlayerPaused() {
        // Apple requires waiting for the viewer after a media-services reset.
        // A renderer that failed on its own is replaced and resumes.
        #expect(AudioRendererReplacement.mediaServicesReset.staysPaused)
        #expect(!AudioRendererReplacement.rendererFailed.staysPaused)
    }

    @Test func aFailedAudioRendererReportsItsOwnReasonWhenItCannotBeReplaced() {
        // Reached only when replacement fails, so show AVFoundation's reason.
        #expect(
            AudioRendererReplacement.rendererFailed
                .failureMessage(detail: "The operation could not be completed")
                .contains("The operation could not be completed")
        )
        // No error: no empty parenthetical.
        let bare = AudioRendererReplacement.rendererFailed.failureMessage(detail: nil)
        #expect(!bare.contains("("))
        #expect(AudioRendererReplacement.rendererFailed.failureMessage(detail: "") == bare)
        // A reset states its cause; the renderer's error is noise.
        #expect(
            AudioRendererReplacement.mediaServicesReset.failureMessage(detail: "ignored")
                == "Playback audio could not recover after the media service restarted."
        )
    }

    @Test func stallRecoveryResumesOnlyWithACushionAndCannotWaitForever() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount - 1,
            videoQueueFinished: false
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 0,
            videoQueueFinished: true
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: StallRecoveryPolicy.reprimeAfter,
            videoQueueCount: 0,
            videoQueueFinished: false
        ) == .reprime)
    }

    @Test func episodeHandoffWaitsForTheSpecificOutgoingPipeline() async {
        let outgoing = UUID()
        let unrelated = UUID()
        PlaybackLifecycleDiagnostics.demuxStarted(outgoing)
        PlaybackLifecycleDiagnostics.renderersAttached(outgoing)
        PlaybackLifecycleDiagnostics.demuxStarted(unrelated)
        defer {
            PlaybackLifecycleDiagnostics.demuxEnded(outgoing)
            PlaybackLifecycleDiagnostics.renderersDetached(outgoing)
            PlaybackLifecycleDiagnostics.demuxEnded(unrelated)
        }

        let retirement = Task {
            await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
                for: outgoing,
                timeout: .seconds(1)
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        PlaybackLifecycleDiagnostics.demuxEnded(outgoing)
        PlaybackLifecycleDiagnostics.renderersDetached(outgoing)

        #expect(await retirement.value)
        #expect(PlaybackLifecycleDiagnostics.snapshot().activeDemuxLoops >= 1)
    }

    @Test func episodeHandoffRetirementTimeoutCannotBecomeSuccess() async {
        let outgoing = UUID()
        PlaybackLifecycleDiagnostics.renderersAttached(outgoing)
        defer { PlaybackLifecycleDiagnostics.renderersDetached(outgoing) }

        let retired = await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
            for: outgoing,
            timeout: .milliseconds(20)
        )

        #expect(!retired)
    }
}
