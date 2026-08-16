import Foundation
import VideoToolbox

// Capability profile sent with PlaybackInfo so the server can decide between
// direct play and transcoding. Mirrors what AVPlayer handles natively:
// mp4-family containers with H.264/HEVC (SDR through HDR10/HLG/Dolby Vision),
// and fMP4 HLS for everything else.
nonisolated enum DeviceProfile {
    struct Profile: Encodable {
        let maxStreamingBitrate: Int
        let maxStaticBitrate: Int
        let directPlayProfiles: [DirectPlayProfile]
        let transcodingProfiles: [TranscodingProfile]
        let codecProfiles: [CodecProfile]
        let subtitleProfiles: [SubtitleProfile]
    }

    struct DirectPlayProfile: Encodable {
        let container: String
        let type: String
        var videoCodec: String?
        var audioCodec: String?
    }

    struct TranscodingProfile: Encodable {
        let container: String
        let type: String
        let videoCodec: String
        let audioCodec: String
        let context: String
        let `protocol`: String
        let maxAudioChannels: String
        let minSegments: Int
        let breakOnNonKeyFrames: Bool
    }

    struct CodecProfile: Encodable {
        let type: String
        let codec: String
        let conditions: [ProfileCondition]
    }

    // isRequired false lets streams whose property the server couldn't probe
    // pass the condition; the server-side default is true, so encode it always.
    struct ProfileCondition: Encodable {
        let condition: String
        let property: String
        let value: String
        let isRequired: Bool
    }

    struct SubtitleProfile: Encodable {
        let format: String
        let method: String
    }

    /// The profile to negotiate with right now. MKV direct play is only real
    /// when the mpv engine will do the playing (HEL-45), so the widened
    /// profile rides the same toggle as the engine routing (exposed in all
    /// builds while experimental — TestFlight testing needs it).
    static var current: Profile {
        UserDefaults.standard.bool(forKey: "debug.mpvForMKV") ? mpvExtended : native
    }

    // Matroska handled by mpv/FFmpeg: software decode where VideoToolbox
    // can't (vc1, vp9, av1 via dav1d), DTS/TrueHD decoded to multichannel
    // LPCM. The hevc CodecProfile conditions still apply, so DoVi profile 7
    // keeps falling back to the HDR10 remux for now.
    static let mpvExtended = Profile(
        maxStreamingBitrate: native.maxStreamingBitrate,
        maxStaticBitrate: native.maxStaticBitrate,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mkv,webm",
                type: "Video",
                videoCodec: "hevc,h264,mpeg4,vp9,av1,vc1",
                audioCodec: "aac,mp3,ac3,eac3,flac,alac,dts,truehd,opus,vorbis"
            ),
        ] + native.directPlayProfiles,
        transcodingProfiles: native.transcodingProfiles,
        codecProfiles: native.codecProfiles,
        subtitleProfiles: native.subtitleProfiles
    )

    static let native: Profile = {
        // AV1 decode is hardware-only for AVPlayer (A17 Pro / M3 and later;
        // no Apple TV has it as of tvOS 26), so advertise it per device.
        // In the transcode list av1 sits last: hevc stays the encode target,
        // av1's presence just lets the server stream-copy AV1 sources.
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

        var codecProfiles = baseCodecProfiles
        if av1 {
            codecProfiles.append(CodecProfile(
                type: "Video",
                codec: "av1",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR|HDR10|HLG|HDR10Plus",
                        isRequired: false
                    ),
                ]
            ))
        }

        return Profile(
            maxStreamingBitrate: 120_000_000,
            maxStaticBitrate: 100_000_000,
            directPlayProfiles: [
                DirectPlayProfile(
                    container: "mp4,m4v,mov",
                    type: "Video",
                    videoCodec: "hevc,h264,mpeg4" + (av1 ? ",av1" : ""),
                    audioCodec: "aac,mp3,ac3,eac3,flac,alac"
                ),
                DirectPlayProfile(container: "mp3", type: "Audio"),
                DirectPlayProfile(container: "m4a,m4b", type: "Audio", audioCodec: "aac,alac"),
                DirectPlayProfile(container: "flac", type: "Audio"),
            ],
            transcodingProfiles: [
                // Container here is the HLS segment container. Apple's HLS stack
                // only accepts HEVC (and any HDR/Dolby Vision signalling) in fMP4
                // segments — never MPEG-TS.
                // Audio codec order is the server's transcode preference:
                // multichannel sources that need an audio transcode (TrueHD, DTS)
                // land on E-AC3 5.1 instead of stereo AAC, while ac3/eac3 source
                // tracks stream-copy — which keeps Atmos (E-AC3 JOC) intact.
                TranscodingProfile(
                    container: "mp4",
                    type: "Video",
                    videoCodec: "hevc,h264" + (av1 ? ",av1" : ""),
                    audioCodec: "eac3,ac3,aac",
                    context: "Streaming",
                    protocol: "hls",
                    maxAudioChannels: "8",
                    minSegments: 1,
                    breakOnNonKeyFrames: true
                ),
            ],
            codecProfiles: codecProfiles,
            subtitleProfiles: [
                SubtitleProfile(format: "vtt", method: "Hls"),
                SubtitleProfile(format: "vtt", method: "External"),
            ]
        )
    }()

    private static let baseCodecProfiles: [CodecProfile] = [
        // Video range types AVPlayer renders natively. Dolby Vision
        // profile 5 is DOVI, profile 8 the DOVIWith* fallbacks; dual-layer
        // profile 7 (DOVIWithEL) is deliberately absent — Apple platforms
        // can't play it, so the server transcodes to the HDR10 base layer.
        CodecProfile(
            type: "Video",
            codec: "hevc",
            conditions: [
                ProfileCondition(
                    condition: "EqualsAny",
                    property: "VideoProfile",
                    value: "main|main 10",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "EqualsAny",
                    property: "VideoRangeType",
                    value: "SDR|HDR10|HLG|DOVI|DOVIWithHDR10|DOVIWithHDR10Plus|DOVIWithHLG|DOVIWithSDR|HDR10Plus",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "LessThanEqual",
                    property: "VideoLevel",
                    value: "183",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "NotEquals",
                    property: "IsAnamorphic",
                    value: "true",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "NotEquals",
                    property: "IsInterlaced",
                    value: "true",
                    isRequired: false
                ),
            ]
        ),
        CodecProfile(
            type: "Video",
            codec: "h264",
            conditions: [
                ProfileCondition(
                    condition: "EqualsAny",
                    property: "VideoProfile",
                    value: "high|main|baseline|constrained baseline",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "EqualsAny",
                    property: "VideoRangeType",
                    value: "SDR",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "LessThanEqual",
                    property: "VideoLevel",
                    value: "52",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "NotEquals",
                    property: "IsAnamorphic",
                    value: "true",
                    isRequired: false
                ),
                ProfileCondition(
                    condition: "NotEquals",
                    property: "IsInterlaced",
                    value: "true",
                    isRequired: false
                ),
            ]
        ),
    ]
}
