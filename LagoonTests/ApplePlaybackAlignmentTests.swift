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

    @Test func vc1DirectPlayIsBoundedToTheSoftwareDecoderEnvelope() {
        let directVideo = DeviceProfile.lagoon.directPlayProfiles.first {
            $0.type == "Video"
        }
        let vc1Profile = DeviceProfile.lagoon.codecProfiles.first {
            $0.type == "Video" && $0.codec == "vc1"
        }

        #expect(directVideo?.videoCodec?.split(separator: ",").contains("vc1") == true)
        #expect(vc1Profile?.conditions.contains {
            $0.property == "Width" && $0.condition == "LessThanEqual" && $0.value == "1920"
        } == true)
        #expect(vc1Profile?.conditions.contains {
            $0.property == "Height" && $0.condition == "LessThanEqual" && $0.value == "1080"
        } == true)
        #expect(vc1Profile?.conditions.contains {
            $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
        } == true)
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_VC1))
        #expect(AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3,
            softwareVideoDecoded: true
        ))
        #expect(!AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3,
            softwareVideoDecoded: false
        ))
        #expect(!AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_EAC3,
            softwareVideoDecoded: true
        ))
    }

    @Test func planarVC1ChromaIsInterleavedIntoCoreVideoNV12Order() {
        let u: [UInt8] = [10, 20, 30, 40]
        let v: [UInt8] = [50, 60, 70, 80]
        var output = [UInt8](repeating: 0xFF, count: 12)

        u.withUnsafeBufferPointer { sourceU in
            v.withUnsafeBufferPointer { sourceV in
                output.withUnsafeMutableBufferPointer { destination in
                    SoftwareVideoDecoder.interleave420Chroma(
                        sourceU: sourceU.baseAddress!,
                        sourceUStride: 2,
                        sourceV: sourceV.baseAddress!,
                        sourceVStride: 2,
                        destination: destination.baseAddress!,
                        destinationStride: 6,
                        width: 4,
                        rows: 2
                    )
                }
            }
        }

        #expect(output == [10, 50, 20, 60, 0xFF, 0xFF, 30, 70, 40, 80, 0xFF, 0xFF])
    }

    /// Opt-in real-bitstream check used by the playback verification command.
    /// Keeping the fixture URL outside the repository avoids shipping a large
    /// third-party media file while still exercising libavformat → VC-1 decode
    /// → CVPixelBuffer → CMSampleBuffer end to end.
    @Test func vc1FixtureProducesReadyCoreVideoFrames() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_VC1_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == "vc1")
        #expect(demuxer.outputsDecodedVideo)
        #expect(!demuxer.audioStreams.isEmpty)
        if let audio = demuxer.audioStreams.first {
            demuxer.selectAudio(streamIndex: audio.streamIndex)
        }

        var decodedFrames = 0
        var audioBuffers = 0
        var audioGaps = 0
        var expectedAudioPTS: CMTime?
        for _ in 0..<1_000 where decodedFrames < 12 || audioBuffers < 2 {
            switch demuxer.readNext() {
            case .video(let buffer):
                #expect(CMSampleBufferDataIsReady(buffer))
                #expect(CMSampleBufferGetImageBuffer(buffer) != nil)
                decodedFrames += 1
            case .audio(let buffers, _):
                for buffer in buffers {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                    if let expectedAudioPTS,
                       abs(CMTimeSubtract(pts, expectedAudioPTS).seconds) > 0.001 {
                        audioGaps += 1
                    }
                    let duration = CMSampleBufferGetDuration(buffer)
                    expectedAudioPTS = pts.isValid && duration.isValid
                        ? CMTimeAdd(pts, duration)
                        : nil
                    audioBuffers += 1
                }
            case .failed(let message):
                Issue.record("VC-1 fixture failed: \(message)")
                return
            case .endOfFile:
                break
            default:
                continue
            }
        }
        #expect(decodedFrames == 12)
        #expect(audioBuffers >= 2)
        #expect(audioGaps == 0)
    }

    @Test func mpeg4DirectPlayIsBoundedToTheSoftwareDecoderEnvelope() {
        let directVideo = DeviceProfile.lagoon.directPlayProfiles.first {
            $0.type == "Video"
        }
        let mpeg4Profile = DeviceProfile.lagoon.codecProfiles.first {
            $0.type == "Video" && $0.codec == "mpeg4"
        }

        #expect(directVideo?.container.split(separator: ",").contains("avi") == true)
        #expect(directVideo?.videoCodec?.split(separator: ",").contains("mpeg4") == true)
        // Widening the envelope must not drop what already direct-played.
        #expect(directVideo?.videoCodec?.split(separator: ",").contains("hevc") == true)
        #expect(directVideo?.videoCodec?.split(separator: ",").contains("h264") == true)
        #expect(directVideo?.videoCodec?.split(separator: ",").contains("vc1") == true)
        for container in ["mkv", "webm", "mp4", "m4v", "mov"] {
            #expect(directVideo?.container.split(separator: ",").contains(Substring(container)) == true)
        }

        #expect(mpeg4Profile?.conditions.contains {
            $0.property == "Width" && $0.condition == "LessThanEqual" && $0.value == "1920"
        } == true)
        #expect(mpeg4Profile?.conditions.contains {
            $0.property == "Height" && $0.condition == "LessThanEqual" && $0.value == "1080"
        } == true)
        #expect(mpeg4Profile?.conditions.contains {
            $0.property == "VideoBitDepth" && $0.condition == "LessThanEqual" && $0.value == "8"
        } == true)
        // No deinterlacing stage exists, so interlaced MPEG-4 must transcode.
        #expect(mpeg4Profile?.conditions.contains {
            $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
        } == true)
        // No pixel-aspect handling exists either.
        #expect(mpeg4Profile?.conditions.contains {
            $0.property == "IsAnamorphic" && $0.condition == "NotEquals" && $0.value == "true"
        } == true)

        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_MPEG4))
        // AC-3 beside software-decoded video already routes to local LPCM,
        // so the pairing that made VC-1 stutter covers these files unchanged.
        #expect(AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3,
            softwareVideoDecoded: true
        ))
        // MP3 — what most of these rips carry — stays compressed passthrough.
        #expect(!AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_MP3,
            softwareVideoDecoded: true
        ))
    }

    /// Point `LAGOON_MPEG4_FIXTURE_URL` at a Jellyfin direct-play URL for an
    /// MPEG-4 Part 2 (Xvid/DivX) AVI. Packed-bitstream rips are the
    /// interesting case: one chunk can carry two VOPs, so the decoder returns
    /// several frames for one packet and none for the next, and the "VOP not
    /// coded" markers arrive as 7-byte packets.
    @Test func mpeg4FixtureProducesReadyCoreVideoFrames() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_MPEG4_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == "mpeg4")
        #expect(demuxer.outputsDecodedVideo)
        #expect(!demuxer.audioStreams.isEmpty)
        if let audio = demuxer.audioStreams.first {
            demuxer.selectAudio(streamIndex: audio.streamIndex)
        }

        var decodedFrames = 0
        var audioBuffers = 0
        var audioGaps = 0
        var lastVideoPTS: CMTime?
        var videoWentBackwards = 0
        var expectedAudioPTS: CMTime?
        for _ in 0..<1_000 where decodedFrames < 12 || audioBuffers < 2 {
            switch demuxer.readNext() {
            case .video(let buffer):
                #expect(CMSampleBufferDataIsReady(buffer))
                #expect(CMSampleBufferGetImageBuffer(buffer) != nil)
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                // Frames leave libavcodec in presentation order even when a
                // packed chunk carried two of them.
                if let lastVideoPTS, pts.isValid, pts < lastVideoPTS {
                    videoWentBackwards += 1
                }
                if pts.isValid { lastVideoPTS = pts }
                decodedFrames += 1
            case .audio(let buffers, _):
                for buffer in buffers {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                    if let expectedAudioPTS,
                       abs(CMTimeSubtract(pts, expectedAudioPTS).seconds) > 0.001 {
                        audioGaps += 1
                    }
                    let duration = CMSampleBufferGetDuration(buffer)
                    expectedAudioPTS = pts.isValid && duration.isValid
                        ? CMTimeAdd(pts, duration)
                        : nil
                    audioBuffers += 1
                }
            case .failed(let message):
                Issue.record("MPEG-4 fixture failed: \(message)")
                return
            case .endOfFile:
                break
            default:
                continue
            }
        }
        #expect(decodedFrames == 12)
        #expect(audioBuffers >= 2)
        #expect(audioGaps == 0)
        #expect(videoWentBackwards == 0)
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

    @Test func demuxSoftVideoLimitYieldsToAudioStarvation() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 90,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        )

        #expect(decision == .read)
    }

    @Test func demuxHardVideoLimitPacesWithoutGrowingUnbounded() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 120,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        )

        #expect(decision == .waitForVideo(below: 120))
    }

    @Test func demuxUsesBatchedVideoDrainWhenAudioHasEnoughReserve() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 90,
            audioCount: 100,
            audioBufferedSeconds: 2.1,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        )

        #expect(decision == .waitForVideo(below: 72))
    }

    @Test func demuxDoesNotWaitForAudioOnSilentVideo() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 90,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: false
        )

        #expect(decision == .waitForVideo(below: 72))
    }

    @Test func demuxHardAudioLimitPacesWhileVideoNeedsData() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 0,
            audioCount: 270,
            audioBufferedSeconds: 6,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        )

        #expect(decision == .waitForAudio(below: 270))
    }

    @Test func softwareDecodedVC1KeepsAOneSecondVideoReserve() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 100,
            audioBufferedSeconds: 3,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: true
        )

        #expect(decision == .waitForVideo(below: 24))
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true
        ) == 42)
        #expect(StallRecoveryPolicy.confirmationDelay == .seconds(1))
    }

}
