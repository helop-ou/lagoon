import Foundation
import LagoonEngine

// Capability profile sent with PlaybackInfo so the server can choose direct
// play or transcode. It mirrors what the engine plays; anything outside it
// arrives as the fMP4 HLS transcode. The generated table is
// docs/codec-support.md.
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

    // isRequired false lets unprobed streams pass. The server defaults it to
    // true, so always encode it.
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

    /// Every format the engine plays, before this device's limits are
    /// subtracted. `lagoon` is what gets sent.
    static let everything = Profile(
        maxStreamingBitrate: 120_000_000,
        maxStaticBitrate: 100_000_000,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mkv,webm,mp4,m4v,mov,avi,mpg,mpeg,ts,mpegts,m2ts,vob",
                type: "Video",
                videoCodec: "hevc,h264,av1,vp9,vc1,wmv3,mpeg4,mpeg2video",
                audioCodec: "aac,mp3,mp2,ac3,eac3,dts,truehd,flac,alac,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be,pcm_f64be,pcm_bluray,pcm_dvd"
            ),
            DirectPlayProfile(container: "mp3", type: "Audio"),
            DirectPlayProfile(container: "m4a,m4b", type: "Audio", audioCodec: "aac,alac"),
            DirectPlayProfile(container: "flac", type: "Audio"),
        ],
        transcodingProfiles: [
            // fMP4 segments: Apple's HLS only takes HEVC and HDR/DV in fMP4,
            // never MPEG-TS. Audio order is the server's preference: TrueHD
            // and DTS become E-AC3 5.1, not stereo AAC, and ac3/eac3 stream-copy,
            // which keeps Atmos intact.
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
            // Dolby Vision profile 5 is DOVI, profile 8 the DOVIWith* ranges.
            // Profile 7 (DOVIWithEL*) direct-plays too: the demuxer converts
            // it to profile 8.1 with libdovi and drops the enhancement layer.
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
                        value: "SDR|HDR10|HLG|DOVI|DOVIWithHDR10|DOVIWithHDR10Plus|DOVIWithHLG|DOVIWithSDR|DOVIWithEL|DOVIWithELHDR10Plus|HDR10Plus",
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
                    // No interlace guard: the demuxer sends interlaced H.264
                    // to the software decoder, which deinterlaces. HEVC keeps
                    // its guard because it has no software route.
                ]
            ),
            // AV1 direct-plays everywhere: VideoToolbox where the hardware
            // has it, dav1d otherwise. Only the software path gets a
            // resolution ceiling (see `boundedTo4K`).
            CodecProfile(
                type: "Video",
                codec: "av1",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoProfile",
                        value: "main",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR|HDR10|HLG|HDR10Plus",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "10",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: true
                    ),
                ]
            ),
            // No public VP9 VideoToolbox path on tvOS, so software, capped at
            // 1080p. Profiles 0 and 2 are 8- and 10-bit 4:2:0.
            CodecProfile(
                type: "Video",
                codec: "vp9",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoProfile",
                        value: "profile 0|profile 2",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR|HDR10|HLG|HDR10Plus",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "10",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Width",
                        value: "1920",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Height",
                        value: "1080",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: true
                    ),
                ]
            ),
            // No VC-1 in VideoToolbox on tvOS: software decode, bounded to
            // 8-bit 1080p. Interlaced VC-1 still transcodes.
            CodecProfile(
                type: "Video",
                codec: "vc1",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "8",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Width",
                        value: "1920",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Height",
                        value: "1080",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: true
                    ),
                ]
            ),
            // WMV3 is VC-1's Simple/Main family and uses the same software
            // decoder and bounds. The container list has no asf/wmv, so this
            // only reaches WMV3 in mkv/avi.
            CodecProfile(
                type: "Video",
                codec: "wmv3",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "8",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Width",
                        value: "1920",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Height",
                        value: "1080",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: true
                    ),
                ]
            ),
            // MPEG-4 Part 2 (Xvid/DivX): software decode like VC-1. Its real
            // profiles are 8-bit 4:2:0; anything else transcodes.
            CodecProfile(
                type: "Video",
                codec: "mpeg4",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "8",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Width",
                        value: "1920",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Height",
                        value: "1080",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: true
                    ),
                ]
            ),
            // No interlace guard: the MPEG-2 software path deinterlaces.
            // Hardware-decoded codecs keep the guard; they have no
            // deinterlacing stage.
            CodecProfile(
                type: "Video",
                codec: "mpeg2video",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "8",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Width",
                        value: "1920",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Height",
                        value: "1080",
                        isRequired: true
                    ),
                ]
            ),
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: "Hls"),
            SubtitleProfile(format: "vtt", method: "External"),
            // Without these the server burns subtitles in, forcing a transcode.
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
            SubtitleProfile(format: "dvbsub", method: "Embed"),
        ]
    )

    /// The full envelope minus what this device's hardware cannot decode.
    static var lagoon: Profile { profile(for: .current) }

    /// The profile for one ladder rung. Only the transcode rung differs.
    /// The metered cap applies last so it also bounds the transcode rung.
    static func lagoon(for delivery: PlaybackDelivery) -> Profile {
        let forRung = delivery == .transcode ? boundedForRealtimeTranscode(lagoon) : lagoon
        return cappedForMeteredPath(forRung)
    }

    /// Bounds a profile on a metered path; untouched otherwise. iOS only:
    /// an Apple TV never reports an expensive path.
    static func cappedForMeteredPath(
        _ profile: Profile,
        cost: NetworkPathCost = NetworkPathObserver.shared.current,
        allowFullQuality: Bool = UserDefaults.standard.bool(forKey: meteredOverrideKey)
    ) -> Profile {
        #if os(iOS)
        guard MeteredPathPolicy.applies(cost: cost, allowFullQuality: allowFullQuality) else {
            return profile
        }
        let bitrate = MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: profile.maxStreamingBitrate,
            cost: cost,
            allowFullQuality: allowFullQuality
        )
        return Profile(
            maxStreamingBitrate: bitrate,
            // The server checks the static ceiling before offering the
            // original file, so it must come down too.
            maxStaticBitrate: min(profile.maxStaticBitrate, bitrate),
            directPlayProfiles: profile.directPlayProfiles,
            transcodingProfiles: profile.transcodingProfiles,
            codecProfiles: profile.codecProfiles.map {
                boundedTo(
                    $0,
                    width: MeteredPathPolicy.maxWidth,
                    height: MeteredPathPolicy.maxHeight
                )
            },
            subtitleProfiles: profile.subtitleProfiles
        )
        #else
        return profile
        #endif
    }

    /// The defaults key behind Settings → Playback → Full Quality on Cellular.
    static let meteredOverrideKey = "playback.allowFullQualityOnMetered"

    /// The transcode rung's bitrate. The envelope's 120 Mbps is a
    /// direct-play figure, not an encoder target.
    static let realtimeTranscodeBitrateCeiling = 20_000_000

    /// Bounds the transcode rung to HD. Unbounded, a server without a
    /// hardware encoder re-encodes 4K far below realtime (9.5 fps for a
    /// 30 fps source) and stalls. Never apply to `remux`: a resolution
    /// condition there forces the re-encode that rung avoids.
    static func boundedForRealtimeTranscode(_ profile: Profile) -> Profile {
        Profile(
            maxStreamingBitrate: min(profile.maxStreamingBitrate, realtimeTranscodeBitrateCeiling),
            maxStaticBitrate: profile.maxStaticBitrate,
            directPlayProfiles: profile.directPlayProfiles,
            transcodingProfiles: profile.transcodingProfiles,
            codecProfiles: profile.codecProfiles.map { boundedToHD($0) },
            subtitleProfiles: profile.subtitleProfiles
        )
    }

    /// Subtracts from `everything` rather than rebuilding it.
    ///
    /// Without hardware HEVC, HEVC leaves three places: direct play, the
    /// codec profile, and above all the transcoding profile, or the server
    /// can answer a transcode with the HEVC this device cannot decode.
    static func profile(for capabilities: PlaybackCapabilities) -> Profile {
        subtractingUnsupported(everything, for: capabilities)
    }

    /// The transform over any envelope, so tests can feed it other shapes.
    static func subtractingUnsupported(
        _ envelope: Profile,
        for capabilities: PlaybackCapabilities
    ) -> Profile {
        var directPlayProfiles = envelope.directPlayProfiles
        var transcodingProfiles = envelope.transcodingProfiles
        var codecProfiles = envelope.codecProfiles

        if !capabilities.hardwareHEVC {
            // Drop an HEVC-only profile, never blank it: Jellyfin reads an
            // empty codec list as "no constraint".
            directPlayProfiles = directPlayProfiles.compactMap { profile in
                guard let videoCodec = profile.videoCodec else { return profile }
                guard let kept = withoutHEVC(videoCodec) else { return nil }
                var reduced = profile
                reduced.videoCodec = kept
                return reduced
            }
            transcodingProfiles = transcodingProfiles.compactMap { profile in
                guard let videoCodec = withoutHEVC(profile.videoCodec) else { return nil }
                return TranscodingProfile(
                    container: profile.container,
                    type: profile.type,
                    videoCodec: videoCodec,
                    audioCodec: profile.audioCodec,
                    context: profile.context,
                    protocol: profile.protocol,
                    maxAudioChannels: profile.maxAudioChannels,
                    minSegments: profile.minSegments,
                    breakOnNonKeyFrames: profile.breakOnNonKeyFrames
                )
            }
            codecProfiles = codecProfiles
                .filter { $0.codec != "hevc" }
                .map { boundedToHD($0, codec: "h264") }
        }
        if !capabilities.hardwareAV1 {
            codecProfiles = codecProfiles.map { boundedTo4K($0, codec: "av1") }
        }

        return Profile(
            maxStreamingBitrate: envelope.maxStreamingBitrate,
            maxStaticBitrate: envelope.maxStaticBitrate,
            directPlayProfiles: directPlayProfiles,
            transcodingProfiles: transcodingProfiles,
            codecProfiles: codecProfiles,
            subtitleProfiles: envelope.subtitleProfiles
        )
    }

    /// Caps H.264 at 1080p on a device without HEVC. Otherwise a 4K HEVC
    /// film transcodes to 4K H.264, which that hardware cannot decode
    /// either. A heuristic: VideoToolbox answers per codec, not per
    /// resolution.
    private static func boundedToHD(_ profile: CodecProfile, codec: String) -> CodecProfile {
        guard profile.codec == codec else { return profile }
        return boundedToHD(profile)
    }

    /// Software AV1's ceiling. Threaded dav1d decodes 30 s of 4K in 1.66 s.
    /// 8K is unmeasured, so it stays bounded.
    private static func boundedTo4K(_ profile: CodecProfile, codec: String) -> CodecProfile {
        guard profile.codec == codec else { return profile }
        return boundedTo(profile, width: 3840, height: 2160)
    }

    private static func boundedToHD(_ profile: CodecProfile) -> CodecProfile {
        boundedTo(profile, width: 1920, height: 1080)
    }

    /// Replaces any Width/Height pair with the smaller ceiling, so two
    /// transforms (metered 720p, fallback 1080p) never leave a
    /// contradictory pair.
    static func boundedTo(_ profile: CodecProfile, width: Int, height: Int) -> CodecProfile {
        guard profile.type == "Video" else { return profile }
        var conditions = profile.conditions.filter {
            !($0.property == "Width" || $0.property == "Height")
        }
        let existingWidth = profile.conditions
            .first { $0.property == "Width" }
            .flatMap { Int($0.value) }
        let existingHeight = profile.conditions
            .first { $0.property == "Height" }
            .flatMap { Int($0.value) }
        conditions.append(ProfileCondition(
            condition: "LessThanEqual",
            property: "Width",
            value: String(min(width, existingWidth ?? width)),
            isRequired: true
        ))
        conditions.append(ProfileCondition(
            condition: "LessThanEqual",
            property: "Height",
            value: String(min(height, existingHeight ?? height)),
            isRequired: true
        ))
        return CodecProfile(type: profile.type, codec: profile.codec, conditions: conditions)
    }

    /// nil when nothing is left; callers then drop the profile.
    private static func withoutHEVC(_ codecs: String) -> String? {
        let kept = codecs.split(separator: ",").filter { $0 != "hevc" }
        return kept.isEmpty ? nil : kept.joined(separator: ",")
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The simulator has no reliable HEVC/DV decoder, so UI regression tests
    /// ask for an H.264/AAC HLS rendition.
    static let simulatorRegression = Profile(
        // Light enough for deterministic seek tests on a 4K source.
        maxStreamingBitrate: 4_000_000,
        maxStaticBitrate: 100_000_000,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mkv,webm,mp4,m4v,mov",
                type: "Video",
                videoCodec: "h264,vc1",
                audioCodec: "aac,mp3,ac3,eac3"
            ),
            DirectPlayProfile(container: "mp3", type: "Audio"),
            DirectPlayProfile(container: "m4a,m4b", type: "Audio", audioCodec: "aac,alac"),
            DirectPlayProfile(container: "flac", type: "Audio"),
        ],
        transcodingProfiles: [
            TranscodingProfile(
                container: "mp4",
                type: "Video",
                videoCodec: "h264",
                audioCodec: "aac",
                context: "Streaming",
                protocol: "hls",
                maxAudioChannels: "6",
                minSegments: 1,
                breakOnNonKeyFrames: true
            ),
        ],
        codecProfiles: [
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
                ]
            ),
            CodecProfile(
                type: "Video",
                codec: "vc1",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoRangeType",
                        value: "SDR",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "VideoBitDepth",
                        value: "8",
                        isRequired: false
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Width",
                        value: "1920",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "LessThanEqual",
                        property: "Height",
                        value: "1080",
                        isRequired: true
                    ),
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: true
                    ),
                ]
            ),
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: "Hls"),
            SubtitleProfile(format: "vtt", method: "External"),
            SubtitleProfile(format: "subrip", method: "External"),
            SubtitleProfile(format: "srt", method: "External"),
        ]
    )
    #endif
}
