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
        let directVideo = DeviceProfile.everything.directPlayProfiles.first {
            $0.type == "Video"
        }
        let vc1Profile = DeviceProfile.everything.codecProfiles.first {
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

    @Test func planar10BitFramesAreShiftedAndInterleavedIntoP010() {
        let y: [UInt16] = [
            0, 1, 512, 1023, 77,
            10, 20, 30, 40, 88,
        ]
        var outputY = [UInt16](repeating: 0xFFFF, count: 12)
        y.withUnsafeBufferPointer { source in
            outputY.withUnsafeMutableBufferPointer { destination in
                SoftwareVideoDecoder.shift10BitPlaneToP010(
                    source: source.baseAddress!,
                    sourceStride: 5 * MemoryLayout<UInt16>.stride,
                    destination: destination.baseAddress!,
                    destinationStride: 6 * MemoryLayout<UInt16>.stride,
                    width: 4,
                    rows: 2
                )
            }
        }
        #expect(outputY == [
            0, 64, 32_768, 65_472, 0xFFFF, 0xFFFF,
            640, 1_280, 1_920, 2_560, 0xFFFF, 0xFFFF,
        ])

        let u: [UInt16] = [1, 512, 77, 2, 100, 88]
        let v: [UInt16] = [1023, 0, 77, 500, 700, 88]
        var outputUV = [UInt16](repeating: 0xFFFF, count: 12)
        u.withUnsafeBufferPointer { sourceU in
            v.withUnsafeBufferPointer { sourceV in
                outputUV.withUnsafeMutableBufferPointer { destination in
                    SoftwareVideoDecoder.interleave420Chroma10BitToP010(
                        sourceU: sourceU.baseAddress!,
                        sourceUStride: 3 * MemoryLayout<UInt16>.stride,
                        sourceV: sourceV.baseAddress!,
                        sourceVStride: 3 * MemoryLayout<UInt16>.stride,
                        destination: destination.baseAddress!,
                        destinationStride: 6 * MemoryLayout<UInt16>.stride,
                        width: 4,
                        rows: 2
                    )
                }
            }
        }
        #expect(outputUV == [
            64, 65_472, 32_768, 0, 0xFFFF, 0xFFFF,
            128, 32_000, 6_400, 44_800, 0xFFFF, 0xFFFF,
        ])
    }

    @Test func av1AndVP9AreBoundedToTheTenBitSoftwareEnvelope() {
        let directVideo = DeviceProfile.everything.directPlayProfiles.first { $0.type == "Video" }
        let codecs = directVideo?.videoCodec?.split(separator: ",") ?? []
        #expect(codecs.contains("av1"))
        #expect(codecs.contains("vp9"))
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_AV1))
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_VP9))
        #expect(avcodec_find_decoder(AV_CODEC_ID_AV1) != nil)
        #expect(avcodec_find_decoder_by_name("libdav1d") != nil)
        #expect(avcodec_find_decoder(AV_CODEC_ID_VP9) != nil)

        let softwareProfile = DeviceProfile.profile(
            for: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        )
        for codec in ["av1", "vp9"] {
            let profile = (codec == "av1" ? softwareProfile : DeviceProfile.everything)
                .codecProfiles.first { $0.codec == codec }
            #expect(profile?.conditions.contains {
                $0.property == "VideoBitDepth" && $0.condition == "LessThanEqual" && $0.value == "10"
            } == true)
            #expect(profile?.conditions.contains {
                $0.property == "Width" && $0.condition == "LessThanEqual" && $0.value == "1920"
            } == true)
            #expect(profile?.conditions.contains {
                $0.property == "Height" && $0.condition == "LessThanEqual" && $0.value == "1080"
            } == true)
            #expect(profile?.conditions.contains {
                $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
            } == true)
        }
        let hardwareAV1 = DeviceProfile.profile(
            for: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        ).codecProfiles.first { $0.codec == "av1" }
        #expect(hardwareAV1?.conditions.contains { $0.property == "Width" } == false)
        #expect(hardwareAV1?.conditions.contains { $0.property == "Height" } == false)

        #expect(SoftwareVideoDecoder.outputBitDepth(
            pixelFormat: AV_PIX_FMT_YUV420P10LE,
            bitsPerRawSample: 0,
            bitsPerCodedSample: 0,
            codecID: AV_CODEC_ID_AV1
        ) == 10)
        #expect(SoftwareVideoDecoder.outputBitDepth(
            pixelFormat: AV_PIX_FMT_YUV420P,
            bitsPerRawSample: 0,
            bitsPerCodedSample: 0,
            codecID: AV_CODEC_ID_VP9
        ) == 8)
    }

    @Test func AV1CompressedRoutingRequiresHardwareSupport() {
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_AV1,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        ))
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_AV1,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        ))
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_VP9,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        ))
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264,
            capabilities: PlaybackCapabilities(hardwareHEVC: false, hardwareAV1: false)
        ))
    }

    @Test func av1FixtureProducesReadyP010Frames() throws {
        try assertTenBitSoftwareFixture(
            environmentKey: "LAGOON_AV1_FIXTURE_URL",
            codecName: "av1"
        )
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_AV1_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        )
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(!demuxer.outputsDecodedVideo)
        let subtype = demuxer.videoStream?.formatDescription.map(CMFormatDescriptionGetMediaSubType)
        #expect(subtype == kCMVideoCodecType_AV1)
    }

    @Test func vp9FixtureProducesReadyP010Frames() throws {
        try assertTenBitSoftwareFixture(
            environmentKey: "LAGOON_VP9_FIXTURE_URL",
            codecName: "vp9"
        )
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
        let directVideo = DeviceProfile.everything.directPlayProfiles.first {
            $0.type == "Video"
        }
        let mpeg4Profile = DeviceProfile.everything.codecProfiles.first {
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
        // Anamorphic is deliberately NOT excluded — pixel aspect is carried
        // through the format description now. See
        // anamorphicSourcesAreNoLongerExcludedFromDirectPlay.

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

    @Test func mpeg2PCMAndDVBUseTheExistingLocalDecodePaths() {
        let directVideo = DeviceProfile.everything.directPlayProfiles.first {
            $0.type == "Video"
        }
        let videoCodecs = directVideo?.videoCodec?.split(separator: ",") ?? []
        let audioCodecs = directVideo?.audioCodec?.split(separator: ",") ?? []
        let mpeg2 = DeviceProfile.everything.codecProfiles.first {
            $0.type == "Video" && $0.codec == "mpeg2video"
        }

        #expect(videoCodecs.contains("mpeg2video"))
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_MPEG2VIDEO))
        #expect(avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO) != nil)
        #expect(mpeg2?.conditions.contains {
            $0.property == "Width" && $0.condition == "LessThanEqual" && $0.value == "1920"
        } == true)
        #expect(mpeg2?.conditions.contains {
            $0.property == "Height" && $0.condition == "LessThanEqual" && $0.value == "1080"
        } == true)
        #expect(mpeg2?.conditions.contains {
            $0.property == "VideoBitDepth" && $0.condition == "LessThanEqual" && $0.value == "8"
        } == true)
        #expect(mpeg2?.conditions.contains {
            $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
        } == true)

        // Representative PCM variants cover ordinary little-endian files,
        // big-endian sources, and Blu-ray LPCM. All reach AudioDecoder's
        // generic libavcodec -> Float32 LPCM path.
        let advertisedPCM = [
            "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le",
            "pcm_s16be", "pcm_s24be", "pcm_s32be", "pcm_f32be", "pcm_f64be",
            "pcm_bluray", "pcm_dvd",
        ]
        for codec in advertisedPCM {
            #expect(audioCodecs.contains(Substring(codec)))
            #expect(avcodec_find_decoder_by_name(codec) != nil)
        }

        for container in ["mpg", "mpeg", "ts", "mpegts", "m2ts", "vob"] {
            #expect(directVideo?.container.split(separator: ",").contains(Substring(container)) == true)
        }

        #expect(DeviceProfile.everything.subtitleProfiles.contains {
            $0.format == "dvbsub" && $0.method == "Embed"
        })
        #expect(avcodec_find_decoder(AV_CODEC_ID_DVB_SUBTITLE) != nil)
    }

    @Test func squareAndNearSquarePixelsCarryNoAspectExtension() {
        // Unknown (libavformat's 0/1) and exactly square must stay nil so the
        // format description handed to the renderer, AVDisplayCriteria and
        // VideoToolbox is byte-identical to what shipped before.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 0, den: 1)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1, den: 1)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1920, den: 1920)) == nil)
        // Malformed values fail closed rather than dividing by zero.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 16, den: 0)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: -16, den: 15)) == nil)
        // Rounding artifacts observed in real files: a 3840x1744 HDR remux
        // and a 624x352 AVI. Both are a hundredth of a percent off square.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1_744, den: 1_745)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 180_224, den: 180_219)) == nil)
    }

    @Test func genuineAnamorphicPixelsAreCarriedThrough() {
        // Every standard broadcast/DVD pixel aspect, wide and narrow.
        for (num, den) in [(16, 15), (12, 11), (32, 27), (64, 45), (15, 16), (11, 12)] {
            let aspect = SampleBufferFactory.pixelAspectRatio(
                AVRational(num: Int32(num), den: Int32(den))
            )
            #expect(aspect?.horizontal == Int32(num))
            #expect(aspect?.vertical == Int32(den))
        }
        // The 1% boundary itself, from both sides.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 101, den: 100)) != nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1_001, den: 1_000)) == nil)
    }

    @Test func hardwareWithoutHEVCIsNeverOfferedHEVC() throws {
        // The engine creates its HEVC session with
        // RequireHardwareAcceleratedVideoDecoder, so on a device without one
        // HEVC does not degrade — it fails outright with -12906. Claiming it
        // anyway buys a guaranteed failure.
        let reduced = DeviceProfile.profile(for: PlaybackCapabilities(hardwareHEVC: false))
        let json = try String(
            decoding: JellyfinClient.encoder.encode(reduced),
            as: UTF8.self
        )
        // The strongest form of the assertion: not one mention survives
        // anywhere in what is sent, whichever section it was hiding in.
        #expect(!json.contains("hevc"))

        // Nothing else may be collateral damage. H.264 in particular is NOT
        // gated on hardware: it is handed to the renderer compressed and may
        // be decoded in software — which is exactly how the simulator plays
        // it while reporting no hardware support for any codec at all.
        let directVideo = reduced.directPlayProfiles.first { $0.type == "Video" }
        let codecs = directVideo?.videoCodec?.split(separator: ",") ?? []
        #expect(codecs.contains("h264"))
        #expect(codecs.contains("av1"))
        #expect(codecs.contains("vp9"))
        #expect(codecs.contains("vc1"))
        #expect(codecs.contains("mpeg4"))
        #expect(reduced.codecProfiles.contains { $0.codec == "h264" })
        #expect(reduced.codecProfiles.contains { $0.codec == "vc1" })
        #expect(reduced.codecProfiles.contains { $0.codec == "mpeg4" })
        #expect(reduced.subtitleProfiles.count == DeviceProfile.everything.subtitleProfiles.count)
        #expect(reduced.maxStreamingBitrate == DeviceProfile.everything.maxStreamingBitrate)

        // The transcode profile is the one that would otherwise undo all of
        // this: listing hevc there lets the server answer a fallback request
        // with the very format the device cannot decode.
        #expect(reduced.transcodingProfiles.first?.videoCodec == "h264")
    }

    @Test func aProfileLeftWithNoVideoCodecIsDroppedRatherThanBlanked() {
        // Jellyfin reads both an absent and an empty codec list as "no
        // constraint", so a profile whose every codec was HEVC cannot be
        // blanked — that would offer strictly more than the full envelope.
        let hevcOnly = DeviceProfile.Profile(
            maxStreamingBitrate: 1,
            maxStaticBitrate: 1,
            directPlayProfiles: [
                DeviceProfile.DirectPlayProfile(
                    container: "mkv",
                    type: "Video",
                    videoCodec: "hevc",
                    audioCodec: "aac"
                ),
                DeviceProfile.DirectPlayProfile(container: "mp3", type: "Audio"),
            ],
            transcodingProfiles: [],
            codecProfiles: [],
            subtitleProfiles: []
        )
        let reduced = DeviceProfile.subtractingUnsupported(
            hevcOnly,
            for: PlaybackCapabilities(hardwareHEVC: false)
        )

        #expect(reduced.directPlayProfiles.count == 1)
        // The audio profile has no video codec to lose and must survive.
        #expect(reduced.directPlayProfiles.first?.type == "Audio")
        #expect(!reduced.directPlayProfiles.contains { $0.videoCodec == nil && $0.type == "Video" })
    }

    @Test func aDeviceWithoutHEVCIsNotAskedToPlay4KH264Instead() {
        // Subtracting HEVC has a sharp edge without this: a 4K HEVC film stops
        // direct-playing and the server is asked for H.264 at 4K, because
        // nothing said otherwise — an enormous transcode for a device that
        // cannot decode it either. Verified against Jellyfin 10.11: the
        // conditions come back as MaxWidth=1920, MaxHeight=1080 on the
        // transcode URL.
        let reduced = DeviceProfile.profile(for: PlaybackCapabilities(hardwareHEVC: false))
        let h264 = reduced.codecProfiles.first { $0.codec == "h264" }
        #expect(h264?.conditions.contains {
            $0.property == "Width" && $0.condition == "LessThanEqual" && $0.value == "1920"
        } == true)
        #expect(h264?.conditions.contains {
            $0.property == "Height" && $0.condition == "LessThanEqual" && $0.value == "1080"
        } == true)
        // The conditions the envelope already carried have to survive.
        #expect(h264?.conditions.contains { $0.property == "VideoLevel" } == true)
        #expect(h264?.conditions.contains { $0.property == "IsInterlaced" } == true)

        // Hardware that can decode HEVC keeps 4K H.264, which it can also
        // decode: the ceiling belongs to the reduced profile alone.
        let full = DeviceProfile.everything.codecProfiles.first { $0.codec == "h264" }
        #expect(full?.conditions.contains { $0.property == "Width" } == false)
    }

    @Test func hardwareWithHEVCIsOfferedTheWholeEnvelope() throws {
        // Subtraction only. With the hardware present the profile must be the
        // declared envelope exactly, not a rebuild that drifts from it.
        //
        // Compared as objects rather than bytes: the client's encoder uses a
        // custom key strategy, which costs it stable key ordering, so two
        // encodings of the same value are equal as JSON but not as data.
        let full = try JSONSerialization.jsonObject(
            with: JellyfinClient.encoder.encode(
                DeviceProfile.profile(
                    for: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
                )
            )
        ) as? NSDictionary
        let envelope = try JSONSerialization.jsonObject(
            with: JellyfinClient.encoder.encode(DeviceProfile.everything)
        ) as? NSDictionary
        #expect(full != nil)
        #expect(full == envelope)
    }

    @Test func anamorphicSourcesAreNoLongerExcludedFromDirectPlay() {
        // The engine now carries pixel aspect through, so the profile must
        // not keep asking the server to transcode non-square sources.
        for profile in DeviceProfile.everything.codecProfiles {
            #expect(!profile.conditions.contains { $0.property == "IsAnamorphic" })
        }
        // Interlaced still transcodes — there is no deinterlacing stage.
        let interlacedGuards = DeviceProfile.everything.codecProfiles.filter { profile in
            profile.conditions.contains {
                $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
            }
        }
        #expect(interlacedGuards.count == DeviceProfile.everything.codecProfiles.count)
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

    @Test func embeddedASSFlowsThroughFFmpegWithItsScriptPlaneAndOverrides() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LAGOON_ASS_FIXTURE_URL"],
              !fixture.isEmpty else { return }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: fixture,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        let stream = try #require(demuxer.subtitleStreams.first)
        demuxer.selectSubtitle(streamIndex: stream.streamIndex)

        var decoded: SubtitleTextCue?
        for _ in 0..<200 {
            switch demuxer.readNext() {
            case .subtitle(let events, _):
                for event in events {
                    if case .cue(let cue) = event, let text = cue.textCues.first {
                        decoded = text
                        break
                    }
                }
            case .failed(let message):
                Issue.record("ASS fixture failed: \(message)")
                return
            case .endOfFile:
                break
            default:
                continue
            }
            if decoded != nil { break }
        }

        let cue = try #require(decoded)
        #expect(cue.text == "Top sign")
        #expect(cue.alignment == .topLeft)
        #expect(abs((cue.position?.x ?? 0) - (2.0 / 3.0)) < 0.000_001)
        #expect(abs((cue.position?.y ?? 0) - (1.0 / 6.0)) < 0.000_001)
        #expect(cue.runs.first?.isBold == true)
        #expect(cue.runs.first?.isItalic == true)
        #expect(cue.runs.first?.primaryColor == SubtitleTextColor(
            red: 0x11,
            green: 0x22,
            blue: 0x33,
            alpha: 0xFF
        ))
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

    @Test func fasterPlaybackRetainsMoreVideoBeforeBackpressure() {
        let ordinary = DemuxBackpressurePolicy.decision(
            videoCount: 20,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: false
        )
        let faster = DemuxBackpressurePolicy.decision(
            videoCount: 20,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: false,
            playbackRate: 1.5
        )

        #expect(ordinary == .waitForVideo(below: 12))
        #expect(faster == .read)
    }

    @Test func fasterPlaybackKeepsItsBatchedDrainWindow() {
        // Both watermarks scale with the rate, but each is separately capped
        // so the queue cannot reach its hard limit. Clamping the low water
        // against the already-capped high water collapsed the gap between
        // them to one frame at 2x: the batched drain became a
        // read-one/wait-one handshake, and the decoded queue parked one frame
        // under the hard limit instead of oscillating well below it.
        func drainTarget(
            videoIsDecoded: Bool,
            videoIsSoftwareDecoded: Bool,
            playbackRate: Double
        ) -> Int? {
            let hardLimit = DemuxBackpressurePolicy.videoHardLimit(
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded
            )
            // One under the hard limit is above every scaled high water, so
            // the policy always answers with the low water it would drain to.
            guard case .waitForVideo(let below) = DemuxBackpressurePolicy.decision(
                videoCount: hardLimit - 1,
                audioCount: 0,
                audioBufferedSeconds: 0,
                videoFrameRate: 24,
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded,
                hasAudio: false,
                playbackRate: playbackRate
            ) else { return nil }
            return below
        }

        // Software-decoded video drains 30 -> 24 at 1x. Six frames, and at 2x
        // the high water saturates at 41 of its 42-frame hard limit, so the
        // batch has to be carved out below that rather than above it.
        #expect(drainTarget(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            playbackRate: 1
        ) == 24)
        #expect(drainTarget(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            playbackRate: 2
        ) == 35)

        // Compressed h264 drains 90 -> 72: eighteen frames, and its high
        // water saturates at 119 from 1.5x upward.
        #expect(drainTarget(
            videoIsDecoded: false,
            videoIsSoftwareDecoded: false,
            playbackRate: 1
        ) == 72)
        #expect(drainTarget(
            videoIsDecoded: false,
            videoIsSoftwareDecoded: false,
            playbackRate: 1.5
        ) == 101)
        #expect(drainTarget(
            videoIsDecoded: false,
            videoIsSoftwareDecoded: false,
            playbackRate: 2
        ) == 101)
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

    private func assertTenBitSoftwareFixture(
        environmentKey: String,
        codecName: String
    ) throws {
        guard let rawURL = ProcessInfo.processInfo.environment[environmentKey],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        )
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == codecName)
        #expect(demuxer.outputsDecodedVideo)

        var decodedFrames = 0
        var reads = 0
        readLoop: while decodedFrames < 12, reads < 1_000 {
            reads += 1
            switch demuxer.readNext() {
            case .video(let buffer):
                #expect(CMSampleBufferDataIsReady(buffer))
                let image = try #require(CMSampleBufferGetImageBuffer(buffer))
                let format = CVPixelBufferGetPixelFormatType(image)
                #expect(
                    format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                        || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                )
                decodedFrames += 1
            case .failed(let message):
                Issue.record("\(codecName) fixture failed: \(message)")
                break readLoop
            case .endOfFile:
                break readLoop
            default:
                continue
            }
        }
        #expect(decodedFrames == 12)
    }

}
