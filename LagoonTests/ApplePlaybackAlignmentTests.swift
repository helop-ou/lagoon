import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavutil
import Testing
import VideoToolbox
@testable import Lagoon

struct ApplePlaybackAlignmentTests {
    @Test func ambientViewingEnvironmentUsesAppleH274PayloadLayout() {
        let metadata = AVAmbientViewingEnvironment(
            ambient_illuminance: AVRational(num: 314, den: 1),
            ambient_light_x: AVRational(num: 15_635, den: 50_000),
            ambient_light_y: AVRational(num: 16_450, den: 50_000)
        )

        #expect(SampleBufferFactory.ambientViewingEnvironmentPayload(metadata) == Data([
            0x00, 0x2F, 0xE9, 0xA0, // 314 lux * 10,000
            0x3D, 0x13,             // CIE x * 50,000
            0x40, 0x42,             // CIE y * 50,000
        ]))
    }

    @Test func invalidAmbientViewingEnvironmentIsNotAttached() {
        let metadata = AVAmbientViewingEnvironment(
            ambient_illuminance: AVRational(num: 0, den: 1),
            ambient_light_x: AVRational(num: 1, den: 2),
            ambient_light_y: AVRational(num: 1, den: 2)
        )

        #expect(SampleBufferFactory.ambientViewingEnvironmentPayload(metadata) == nil)
    }

    @Test func rendererPixelBufferRecommendationsArePreserved() {
        let recommended = CVPixelBufferAttributes(bytesPerRowAlignment: 256)
        let resolved = VideoToolboxDecoder.resolvedPixelBufferAttributes(
            recommended: recommended
        )

        #expect(resolved.bytesPerRowAlignment == 256)
        #expect(resolved.backing == .ioSurface)
        #expect(resolved.compatibility.contains(.metalTexture))
    }

    @Test func hostClockAnchorNeverStartsBeforeTheRequestedPosition() {
        let beforeTarget = PlaybackClockAnchor.mediaTime(
            targetSeconds: 10,
            firstVideoPTS: CMTime(seconds: 9, preferredTimescale: 24_000)
        )
        let afterTarget = PlaybackClockAnchor.mediaTime(
            targetSeconds: 10,
            firstVideoPTS: CMTime(seconds: 10.5, preferredTimescale: 24_000)
        )
        let invalid = PlaybackClockAnchor.mediaTime(
            targetSeconds: 10,
            firstVideoPTS: .invalid
        )

        #expect(beforeTarget.seconds == 10)
        #expect(afterTarget.seconds == 10.5)
        #expect(invalid.seconds == 10)
    }

    @Test func missingReferenceIsARecoverableFrameError() {
        #expect(VideoToolboxDecoder.isRecoverableFrameError(kVTVideoDecoderReferenceMissingErr))
        #expect(!VideoToolboxDecoder.isRecoverableFrameError(kVTVideoDecoderMalfunctionErr))
        #expect(!VideoToolboxDecoder.isRecoverableFrameError(kVTInvalidSessionErr))
    }

    @Test func directPlayAudioCadenceUsesCodecConfiguration() {
        #expect(SampleBufferFactory.audioFramesPerPacket(
            codecID: AV_CODEC_ID_MP3,
            sampleRate: 24_000,
            declaredFrameSize: 0
        ) == 576)
        #expect(SampleBufferFactory.audioFramesPerPacket(
            codecID: AV_CODEC_ID_MP3,
            sampleRate: 48_000,
            declaredFrameSize: 0
        ) == 1152)
        #expect(SampleBufferFactory.audioFramesPerPacket(
            codecID: AV_CODEC_ID_AAC,
            sampleRate: 48_000,
            declaredFrameSize: 960
        ) == 960)
    }

    @Test func failedFFmpegSeekStatusIsRejected() {
        var threw = false
        do {
            try FFmpegDemuxer.validateSeekStatus(-1)
        } catch {
            threw = true
        }
        #expect(threw)
        do {
            try FFmpegDemuxer.validateSeekStatus(0)
        } catch {
            Issue.record("A successful FFmpeg seek status threw: \(error)")
        }
    }

    @Test func playbackEndUsesObservedSamplesWithoutContainerDuration() {
        #expect(PlaybackEndBoundary.endTime(sampledEnd: 42.25, declaredDuration: 0) == 42.25)
        #expect(PlaybackEndBoundary.endTime(sampledEnd: 41.5, declaredDuration: 99) == 41.5)
        #expect(PlaybackEndBoundary.endTime(sampledEnd: 0, declaredDuration: 99) == 99)
        #expect(PlaybackEndBoundary.endTime(sampledEnd: .nan, declaredDuration: .infinity) == nil)
    }
}
