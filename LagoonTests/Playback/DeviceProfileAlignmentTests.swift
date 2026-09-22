import Foundation
import Libavcodec
import Testing
@testable import Lagoon
@testable import LagoonEngine

/// What the device profile offers a server, checked against what the engine
/// can decode. Each test checks both sides agree, which is why this file
/// reaches into the engine and links libavcodec when the app does neither.
struct DeviceProfileAlignmentTests {
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

    /// WMV3 shares VC-1's decoder path, so it gets the same envelope.
    @Test func wmv3DirectPlayIsBoundedToTheSameEnvelopeAsVC1() {
        let directVideo = DeviceProfile.everything.directPlayProfiles.first {
            $0.type == "Video"
        }
        let wmv3Profile = DeviceProfile.everything.codecProfiles.first {
            $0.type == "Video" && $0.codec == "wmv3"
        }

        #expect(directVideo?.videoCodec?.split(separator: ",").contains("wmv3") == true)
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_WMV3))

        let vc1Profile = DeviceProfile.everything.codecProfiles.first {
            $0.type == "Video" && $0.codec == "vc1"
        }
        // Compared as a pair: one decoder, so the envelopes must change together.
        #expect(wmv3Profile?.conditions.count == vc1Profile?.conditions.count)
        for property in ["Width", "Height", "IsInterlaced", "VideoBitDepth", "VideoRangeType"] {
            let wmv3Condition = wmv3Profile?.conditions.first { $0.property == property }
            let vc1Condition = vc1Profile?.conditions.first { $0.property == property }
            #expect(wmv3Condition?.value == vc1Condition?.value, "wmv3/vc1 differ on \(property)")
            #expect(wmv3Condition?.condition == vc1Condition?.condition, "wmv3/vc1 differ on \(property)")
        }
    }

    /// Both decode through `AudioDecoder`'s generic `avcodec_find_decoder`
    /// path. MP2 matters because mpg, ts and vob are already advertised.
    @Test func mp2AndALACAreOfferedInVideoContainers() {
        let directVideo = DeviceProfile.everything.directPlayProfiles.first {
            $0.type == "Video"
        }
        let audioCodecs = directVideo?.audioCodec?.split(separator: ",").map(String.init) ?? []

        #expect(audioCodecs.contains("mp2"))
        #expect(audioCodecs.contains("alac"))
        let containers = directVideo?.container.split(separator: ",").map(String.init) ?? []
        #expect(containers.contains("mpg"))
        #expect(containers.contains("ts"))
        #expect(containers.contains("vob"))
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
                $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
            } == true)
            // Software AV1 (multi-core dav1d) reaches 4K; VP9 stays at HD,
            // since nothing has measured it above that.
            let bound = codec == "av1" ? ("3840", "2160") : ("1920", "1080")
            #expect(profile?.conditions.contains {
                $0.property == "Width" && $0.condition == "LessThanEqual" && $0.value == bound.0
            } == true)
            #expect(profile?.conditions.contains {
                $0.property == "Height" && $0.condition == "LessThanEqual" && $0.value == bound.1
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
        // Anamorphic is not excluded; see
        // anamorphicSourcesAreNoLongerExcludedFromDirectPlay.

        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_MPEG4))
        // AC-3 beside software-decoded video decodes to local LPCM.
        #expect(AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3,
            softwareVideoDecoded: true
        ))
        // MP3, common in these rips, stays compressed passthrough.
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
        // No interlace guard: the software path deinterlaces MPEG-2.
        #expect(mpeg2?.conditions.contains {
            $0.property == "IsInterlaced"
        } == false)

        // Little-endian, big-endian and Blu-ray PCM all reach AudioDecoder's
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

    @Test func hardwareWithoutHEVCIsNeverOfferedHEVC() throws {
        // The engine requires a hardware HEVC decoder; without one HEVC fails
        // outright with -12906.
        let reduced = DeviceProfile.profile(for: PlaybackCapabilities(hardwareHEVC: false))
        let json = try String(
            decoding: JellyfinClient.encoder.encode(reduced),
            as: UTF8.self
        )
        // No mention of hevc survives anywhere in the payload.
        #expect(!json.contains("hevc"))

        // Nothing else is dropped. H.264 is not gated on hardware: it may be
        // decoded in software, which is how the simulator plays it.
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

        // Otherwise the server could answer a fallback with HEVC.
        #expect(reduced.transcodingProfiles.first?.videoCodec == "h264")
    }

    @Test func aProfileLeftWithNoVideoCodecIsDroppedRatherThanBlanked() {
        // Jellyfin reads an empty codec list as "no constraint", so blanking
        // an HEVC-only profile would offer everything.
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
        // Without this, a 4K HEVC film transcodes to 4K H.264, which the device
        // cannot decode either. Jellyfin 10.11 turns these into MaxWidth=1920,
        // MaxHeight=1080 on the transcode URL.
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
        #expect(h264?.conditions.contains { $0.property == "VideoProfile" } == true)

        // Hardware with HEVC keeps 4K H.264.
        let full = DeviceProfile.everything.codecProfiles.first { $0.codec == "h264" }
        #expect(full?.conditions.contains { $0.property == "Width" } == false)
    }

    @Test func hardwareWithHEVCIsOfferedTheWholeEnvelope() throws {
        // With the hardware present the profile is the declared envelope
        // exactly. Compared as objects: the encoder's key strategy loses
        // stable key order, so equal values can differ as bytes.
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
        // The engine carries pixel aspect through.
        for profile in DeviceProfile.everything.codecProfiles {
            #expect(!profile.conditions.contains { $0.property == "IsAnamorphic" })
        }
        // Hardware decoding cannot deinterlace, so interlaced content
        // transcodes, except MPEG-2 and interlaced H.264, which decode in
        // software.
        let guarded = DeviceProfile.everything.codecProfiles.filter { profile in
            profile.conditions.contains {
                $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
            }
        }
        let unguarded = DeviceProfile.everything.codecProfiles.filter { profile in
            !profile.conditions.contains { $0.property == "IsInterlaced" }
        }
        #expect(guarded.count + unguarded.count == DeviceProfile.everything.codecProfiles.count)
        #expect(unguarded.map(\.codec) == ["h264", "mpeg2video"])
    }

    @Test func interlacedH264IsRoutedToTheSoftwareDecoderAndProgressiveIsNot() {
        // The demuxer's field-order check splits H.264: interlaced decodes in
        // software, which deinterlaces; progressive stays on VideoToolbox.
        let capabilities = PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264, capabilities: capabilities, interlaced: false
        ))
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264, capabilities: capabilities, interlaced: true
        ))
        // The software decoder takes H.264 only on the interlaced route, so a
        // hardware failure on progressive H.264 never falls back to the CPU.
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_H264, interlaced: true))
        #expect(!SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_H264))
        #expect(!SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_H264, interlaced: false))

        // HEVC has no software route: it stays compressed, and the profile
        // keeps the interlace guard.
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_HEVC, capabilities: capabilities, interlaced: true
        ))
        #expect(!SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_HEVC, interlaced: true))
        let hevc = DeviceProfile.everything.codecProfiles.first { $0.codec == "hevc" }
        #expect(hevc?.conditions.contains {
            $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
        } == true)

        // Unknown counts as progressive, or ordinary H.264 would leave the
        // hardware for nothing.
        for order in [AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT] {
            #expect(FFmpegDemuxer.isInterlaced(fieldOrder: order))
        }
        #expect(!FFmpegDemuxer.isInterlaced(fieldOrder: AV_FIELD_PROGRESSIVE))
        #expect(!FFmpegDemuxer.isInterlaced(fieldOrder: AV_FIELD_UNKNOWN))

        // AC-3, common in broadcast recordings, decodes locally beside it.
        let h264 = DeviceProfile.everything.codecProfiles.first { $0.codec == "h264" }
        #expect(h264?.conditions.contains { $0.property == "IsInterlaced" } == false)
        #expect(AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3,
            softwareVideoDecoded: true
        ))
    }

}
