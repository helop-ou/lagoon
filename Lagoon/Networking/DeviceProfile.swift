import Foundation

// Capability profile sent with PlaybackInfo so the server can decide between
// direct play and transcoding. Since HEL-48 went all-in, it mirrors exactly
// what the Lagoon sample-buffer engine can play: h264/hevc video wrapped
// compressed; aac/mp3/ac3/eac3 audio wrapped compressed plus
// dts/truehd/flac/opus/vorbis decoded to LPCM via libavcodec (M4); text and
// PGS/VobSub subtitles embedded, vtt external (M5) — in any container
// libavformat demuxes, plus the fMP4 HLS transcode fallback (whose
// hevc/h264 + eac3 output lands back inside the same envelope).
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

    static let lagoon = Profile(
        maxStreamingBitrate: 120_000_000,
        maxStaticBitrate: 100_000_000,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mkv,webm,mp4,m4v,mov",
                type: "Video",
                videoCodec: "hevc,h264",
                audioCodec: "aac,mp3,ac3,eac3,dts,truehd,flac,opus,vorbis"
            ),
            DirectPlayProfile(container: "mp3", type: "Audio"),
            DirectPlayProfile(container: "m4a,m4b", type: "Audio", audioCodec: "aac,alac"),
            DirectPlayProfile(container: "flac", type: "Audio"),
        ],
        transcodingProfiles: [
            // Container here is the HLS segment container. Apple's HLS stack
            // only accepts HEVC (and any HDR/Dolby Vision signalling) in fMP4
            // segments — never MPEG-TS — and libavformat reads fMP4 fine.
            // Audio codec order is the server's transcode preference:
            // multichannel sources that need an audio transcode (TrueHD, DTS)
            // land on E-AC3 5.1 instead of stereo AAC, while ac3/eac3 source
            // tracks stream-copy — which keeps Atmos (E-AC3 JOC) intact.
            TranscodingProfile(
                container: "mp4",
                type: "Video",
                videoCodec: "hevc,h264",
                audioCodec: "eac3,ac3,aac",
                context: "Streaming",
                protocol: "hls",
                maxAudioChannels: "8",
                minSegments: 1,
                breakOnNonKeyFrames: true
            ),
        ],
        codecProfiles: [
            // Video range types the pipeline can present. Dolby Vision
            // profile 5 is DOVI, profile 8 the DOVIWith* fallbacks; dual-layer
            // profile 7 (DOVIWithEL) is deliberately absent — the server
            // transcodes those to the HDR10 base layer. (Until HEL-48 M3
            // adds color tagging, HDR sources render without HDR
            // signalling in the Lagoon engine.)
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
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: "Hls"),
            SubtitleProfile(format: "vtt", method: "External"),
            // Embedded formats the engine decodes itself (M5) — without
            // these the server burns subtitles in, forcing a transcode.
            SubtitleProfile(format: "subrip", method: "Embed"),
            SubtitleProfile(format: "srt", method: "Embed"),
            SubtitleProfile(format: "ass", method: "Embed"),
            SubtitleProfile(format: "ssa", method: "Embed"),
            SubtitleProfile(format: "mov_text", method: "Embed"),
            SubtitleProfile(format: "webvtt", method: "Embed"),
            SubtitleProfile(format: "vtt", method: "Embed"),
            SubtitleProfile(format: "pgssub", method: "Embed"),
            SubtitleProfile(format: "pgs", method: "Embed"),
            SubtitleProfile(format: "dvdsub", method: "Embed"),
        ]
    )
}
