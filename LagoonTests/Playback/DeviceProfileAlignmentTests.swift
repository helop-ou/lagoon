import Foundation
import Libavcodec
import Testing
@testable import Lagoon
@testable import LagoonEngine

/// What the device profile offers a server, checked against what the engine
/// can actually decode.
///
/// Split out of `ApplePlaybackAlignmentTests` when the engine moved to its
/// own package: the tests that assert only on decoders went with it. These
/// stayed because each one asserts that two sides agree — the envelope
/// Jellyfin is sent, which is this side's, against the decoder that has to
/// honour it, which is not.
///
/// That is why this file reaches into the engine and links libavcodec while
/// the app itself does neither. A test that checks an agreement has to see
/// both parties; the shipping code only ever sees its own side.
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

    /// WMV3 shares VC-1's decoder path and has always been in
    /// `SoftwareVideoDecoder.supports`; only the profile omitted it, so every
    /// WMV3 file took a server transcode for a decoder already present.
    /// Same envelope as VC-1, for the same reasons.
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
        // Pinned as a pair rather than by repeating the literals: the two
        // ride one decoder, so an envelope change to either that does not
        // reach the other is the bug this catches.
        #expect(wmv3Profile?.conditions.count == vc1Profile?.conditions.count)
        for property in ["Width", "Height", "IsInterlaced", "VideoBitDepth", "VideoRangeType"] {
            let wmv3Condition = wmv3Profile?.conditions.first { $0.property == property }
            let vc1Condition = vc1Profile?.conditions.first { $0.property == property }
            #expect(wmv3Condition?.value == vc1Condition?.value, "wmv3/vc1 differ on \(property)")
            #expect(wmv3Condition?.condition == vc1Condition?.condition, "wmv3/vc1 differ on \(property)")
        }
    }

    /// Both decode through `AudioDecoder`'s generic `avcodec_find_decoder`
    /// path, so the only thing that kept them transcoding was the profile
    /// not naming them. MP2 matters because the containers it
    /// lives in — mpg, ts, vob — are all already advertised.
    @Test func mp2AndALACAreOfferedInVideoContainers() {
        let directVideo = DeviceProfile.everything.directPlayProfiles.first {
            $0.type == "Video"
        }
        let audioCodecs = directVideo?.audioCodec?.split(separator: ",").map(String.init) ?? []

        #expect(audioCodecs.contains("mp2"))
        #expect(audioCodecs.contains("alac"))
        // The containers that make MP2 worth advertising at all.
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
            // AV1 reaches 4K on the software path now that dav1d is allowed
            // more than one core; VP9 keeps the HD bound it was written with,
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
        // MPEG-2 no longer carries an interlace guard: the software path
        // that decodes it deinterlaces what it decodes, so an interlaced DVD
        // or off-air recording is Direct Play like any other.
        #expect(mpeg2?.conditions.contains {
            $0.property == "IsInterlaced"
        } == false)

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
        #expect(h264?.conditions.contains { $0.property == "VideoProfile" } == true)

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
        // Interlaced content still goes to the server for everything that
        // decodes in hardware, where there is no deinterlacing stage. MPEG-2
        // is the exception, because it decodes in software and that path
        // deinterlaces, and so is H.264, whose interlaced streams
        // the demuxer sends down the same software path.
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
        // A 1080i broadcast recording used to transcode because the
        // H.264 profile carried an interlace guard, VideoToolbox having no
        // deinterlacing stage. The guard is gone and the split is now the
        // demuxer's own field-order check: interlaced H.264 decodes in
        // software, where the deinterlacer lives, and progressive H.264 is
        // exactly where it was.
        let capabilities = PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264, capabilities: capabilities, interlaced: false
        ))
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264, capabilities: capabilities, interlaced: true
        ))
        // The software decoder takes H.264 only on the interlaced route, so a
        // hardware description that fails for progressive H.264 keeps
        // failing the way it does today instead of quietly decoding on the
        // CPU.
        #expect(SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_H264, interlaced: true))
        #expect(!SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_H264))
        #expect(!SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_H264, interlaced: false))

        // HEVC has no software route and interlaced HEVC is not something a
        // library holds: it stays compressed whatever the field order says,
        // and the profile keeps asking the server for it.
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_HEVC, capabilities: capabilities, interlaced: true
        ))
        #expect(!SoftwareVideoDecoder.supports(codecID: AV_CODEC_ID_HEVC, interlaced: true))
        let hevc = DeviceProfile.everything.codecProfiles.first { $0.codec == "hevc" }
        #expect(hevc?.conditions.contains {
            $0.property == "IsInterlaced" && $0.condition == "NotEquals" && $0.value == "true"
        } == true)

        // Every field order libavformat can report. Unknown is progressive:
        // it is what a stream that never said reports, and sending that to
        // the CPU would take ordinary H.264 off the hardware for nothing.
        for order in [AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT] {
            #expect(FFmpegDemuxer.isInterlaced(fieldOrder: order))
        }
        #expect(!FFmpegDemuxer.isInterlaced(fieldOrder: AV_FIELD_PROGRESSIVE))
        #expect(!FFmpegDemuxer.isInterlaced(fieldOrder: AV_FIELD_UNKNOWN))

        // The profile no longer refuses it; AC-3 beside software-decoded
        // video already goes local, which is what a broadcast recording
        // pairs it with.
        let h264 = DeviceProfile.everything.codecProfiles.first { $0.codec == "h264" }
        #expect(h264?.conditions.contains { $0.property == "IsInterlaced" } == false)
        #expect(AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3,
            softwareVideoDecoded: true
        ))
    }

    /// Point `LAGOON_INTERLACED_H264_FIXTURE_URL` at an interlaced H.264 file
    /// (a 1080i recording, or `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=25
    /// -vf tinterlace=interleave_top,setfield=tff -c:v libx264 -flags +ilme+ildct
    /// -x264-params tff=1`) and this opens it the way the player does: the
    /// demuxer must take the software route and every decoded frame must
    /// come out progressive, not woven. `LAGOON_PROGRESSIVE_H264_FIXTURE_URL`
    /// is the control: the same encoder without the interlace flags has to
    /// stay on the compressed VideoToolbox path.

}
