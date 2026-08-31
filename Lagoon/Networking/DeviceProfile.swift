import Foundation

// Capability profile sent with PlaybackInfo so the server can decide between
// direct play and transcoding. Since HEL-48 went all-in, it mirrors exactly
// what the Lagoon sample-buffer engine can play: h264 stays compressed,
// hevc is hardware-decoded ahead, AV1 uses hardware when available, and
// progressive AV1/VP9 (up to 10-bit) plus 8-bit VC-1, WMV3, MPEG-4 Part 2,
// and MPEG-2 up to 1080p are software-decoded into Core Video buffers;
// aac/mp3/ac3/eac3 audio stays compressed plus
// non-square pixels carried through as a PixelAspectRatio extension, so
// anamorphic sources (PAL DVD rips at 720x576 with a 16:15 pixel aspect)
// direct-play instead of transcoding;
// dts/truehd/flac/alac/mp2/opus/vorbis/PCM decoded to LPCM via libavcodec
// (M4); text,
// PGS/VobSub/DVB subtitles embedded, vtt external (M5) — in any container
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

    /// Every format the engine knows how to play, before this device's
    /// capabilities are subtracted. Use it to reason about the envelope
    /// itself; `lagoon` is what actually gets sent.
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
            // profile 5 is DOVI, profile 8 the DOVIWith* fallbacks.
            // Dual-layer profile 7 (DOVIWithEL / DOVIWithELHDR10Plus)
            // direct-plays too: the base layer is plain HEVC Main 10
            // HDR10(+), the enhancement-layer NALs are unspecified types
            // the decoder ignores, and tvOS can't reconstruct dual-layer
            // DoVi anyway — so BL-as-HDR10 is the ceiling whether we or
            // the server strip the EL, and direct play skips the lossy
            // server re-encode.
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
                    ProfileCondition(
                        condition: "NotEquals",
                        property: "IsInterlaced",
                        value: "true",
                        isRequired: false
                    ),
                ]
            ),
            // AV1 remains direct play on every supported device: recent
            // Apple silicon takes the compressed stream through VideoToolbox,
            // while older hardware uses the pinned libdav1d decoder and
            // presents NV12/P010 through the same renderer. The capability
            // transform below applies the initial 1080p ceiling only to that
            // software fallback; hardware AV1 keeps the full envelope.
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
            // Apple exposes no public VP9 VideoToolbox path on tvOS. Profiles
            // 0 and 2 cover 8- and 10-bit 4:2:0 respectively; libavcodec emits
            // those as NV12/P010-ready frames within the same conservative
            // 1080p software ceiling as AV1.
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
            // Apple does not expose VC-1 through VideoToolbox on tvOS. Lagoon
            // decodes this deliberately bounded legacy envelope with
            // libavcodec and presents ready NV12 image buffers through the
            // existing AVSampleBufferRenderSynchronizer. Interlaced content
            // still transcodes because the client has no deinterlacing stage.
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
            // WMV3 (WMV9) is the same bitstream family as VC-1 — SMPTE 421M
            // Simple/Main to VC-1's Advanced — and SoftwareVideoDecoder has
            // always listed AV_CODEC_ID_WMV3 beside it. Only the profile
            // omitted it, so every WMV3 file took a server transcode for a
            // decoder already present and already exercised. Same bounds as
            // VC-1 above for the same reasons, including the AC-3 pairing
            // through AudioDecodePolicy.requiresLocalPCM, which keys on
            // software-decoded video rather than on the codec.
            //
            // Note the container list does not include asf/wmv, so this
            // reaches WMV3 remuxed into mkv/avi rather than plain .wmv files.
            // Adding the container is a separate decision (HEL-125).
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
            // MPEG-4 Part 2 (Xvid/DivX) has no VideoToolbox decoder either,
            // and rides the same libavcodec → Core Video path as VC-1. The
            // Simple and Advanced Simple Profiles that real files use are
            // 8-bit 4:2:0 by specification, which is exactly what
            // SoftwareVideoDecoder accepts; the bounds below keep anything
            // outside that legacy envelope on the server transcode. AC-3
            // alongside software-decoded video already routes through
            // AudioDecodePolicy.requiresLocalPCM, so the pairing that made
            // VC-1 stutter is handled for these files too.
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
            // MPEG-2 uses the same 8-bit planar 4:2:0 software path as the
            // other legacy codecs, and that path now deinterlaces what it
            // decodes, so the interlace guard this profile used to carry is
            // gone: an interlaced DVD or recording is Direct Play like any
            // other MPEG-2 (HEL-127). The guard stays on every codec that
            // decodes in hardware, where there is no deinterlacing stage.
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
            SubtitleProfile(format: "dvbsub", method: "Embed"),
        ]
    )

    /// What this device is offered: the full envelope minus anything its
    /// hardware cannot decode.
    static var lagoon: Profile { profile(for: .current) }

    /// What this device is offered for one rung of the delivery ladder
    /// (HEL-100). Only the bottom rung differs, and only because that is
    /// the one rung where the server re-encodes.
    ///
    /// The metered cap is applied after the rung, so a constrained path
    /// bounds the transcode rung too rather than being overwritten by it.
    static func lagoon(for delivery: PlaybackDelivery) -> Profile {
        let forRung = delivery == .transcode ? boundedForRealtimeTranscode(lagoon) : lagoon
        return cappedForMeteredPath(forRung)
    }

    /// Bounds a profile to what a metered path should be asked to carry
    /// (HEL-108), or returns it untouched on an ordinary one.
    ///
    /// **iOS only.** An Apple TV is a wired or strong-Wi-Fi appliance and
    /// Apple has no reason to report its path as expensive, so applying this
    /// there would be dead code that could only ever surprise. Widening it
    /// later is a one-line change if a tvOS device on a hotspot ever turns
    /// out to matter.
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
            // The static ceiling has to come down with it. It is the one the
            // server checks before offering the original file, so leaving it
            // at 100 Mbps would let an 89 Mbps remux direct-play over
            // cellular no matter what the streaming figure said.
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

    /// The ceiling the transcode rung asks for. The envelope's 120 Mbps is
    /// a direct-play figure — the bitrate of an untouched file this device
    /// is willing to pull — and means nothing to an encoder being asked to
    /// produce a new stream.
    static let realtimeTranscodeBitrateCeiling = 20_000_000

    /// Bounds the rung that re-encodes, and only that rung.
    ///
    /// Left unbounded it inherits the envelope: the server is asked to
    /// re-encode at the source's own shape, 4K HEVC at up to 120 Mbps.
    /// A server without a hardware encoder cannot produce that anywhere
    /// near realtime — 9.5 fps for a 30 fps 4K source on the reference
    /// server, which stalls and rebuffers indefinitely. That makes the
    /// rescue rung strictly worse than the failure it exists to rescue,
    /// since the ladder is only ever descended when playback has already
    /// broken once.
    ///
    /// HD is the same heuristic `boundedToHD` applies for a missing
    /// hardware decoder, and errs the same way: toward a stream that
    /// plays. It is deliberately not applied to `remux`, which
    /// stream-copies the video — a resolution condition there would force
    /// the very re-encode that rung exists to avoid.
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

    /// Subtracts rather than rebuilds, so the envelope above stays the single
    /// statement of what the engine can play and this stays a short, testable
    /// transform over it.
    ///
    /// HEVC has to come out in three places, not one. The direct-play list is
    /// the obvious one.
    /// The codec profile has to go too, or the server sees conditions for a
    /// codec it is not being offered. And the **transcoding** profile matters
    /// most: left listing `hevc,h264` it lets a server answer a transcode
    /// request with an HEVC rendition, which is precisely the format this
    /// device just said it cannot decode — a fallback that lands back on the
    /// same failure.
    static func profile(for capabilities: PlaybackCapabilities) -> Profile {
        subtractingUnsupported(everything, for: capabilities)
    }

    /// The transform itself, over any envelope, so it can be exercised
    /// against shapes the shipping literal does not currently take.
    static func subtractingUnsupported(
        _ envelope: Profile,
        for capabilities: PlaybackCapabilities
    ) -> Profile {
        var directPlayProfiles = envelope.directPlayProfiles
        var transcodingProfiles = envelope.transcodingProfiles
        var codecProfiles = envelope.codecProfiles

        if !capabilities.hardwareHEVC {
            // A profile whose every video codec was HEVC is dropped outright,
            // not blanked. Both an absent and an empty codec list read as *no
            // constraint* to Jellyfin, so blanking one would come back
            // offering strictly more than the full envelope did.
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
            codecProfiles = codecProfiles.map { boundedToHD($0, codec: "av1") }
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

    /// Caps one codec at 1080p when it has to use a conservative fallback:
    /// H.264 for a device without HEVC, or AV1 for software libdav1d decode.
    ///
    /// Without this the subtraction has a sharp edge: a 4K HEVC film stops
    /// direct-playing and the server is asked for H.264 instead — at 4K,
    /// because nothing said otherwise. That is an enormous transcode produced
    /// for a device that has no chance of decoding it, and it was observed
    /// doing exactly that (the player sat at 0 s with empty queues while the
    /// server worked). Hardware that cannot decode HEVC is not going to manage
    /// 4K H.264 either. AV1 is the second use of this transform: hardware AV1
    /// keeps the full profile, while the CPU fallback starts at HD.
    ///
    /// A heuristic, not a measurement: VideoToolbox answers per codec, never
    /// per resolution, so there is no API that would make this exact. It errs
    /// toward a stream that plays.
    private static func boundedToHD(_ profile: CodecProfile, codec: String) -> CodecProfile {
        guard profile.codec == codec else { return profile }
        return boundedToHD(profile)
    }

    /// The bound itself, over any video codec profile. Idempotent: the
    /// codecs the envelope already writes a ceiling for (vp9, vc1, wmv3,
    /// mpeg4, mpeg2video) keep the single pair of conditions they were
    /// written with instead of collecting a duplicate set, which matters
    /// once two transforms can each ask for one.
    private static func boundedToHD(_ profile: CodecProfile) -> CodecProfile {
        boundedTo(profile, width: 1920, height: 1080)
    }

    /// One geometry bound, applied to a video codec profile.
    ///
    /// Not idempotent by skipping, but by *tightening*: a codec the envelope
    /// already bounds keeps the smaller of the two ceilings rather than
    /// carrying a contradictory pair. That matters now that two transforms
    /// can each ask for one and they no longer ask for the same number —
    /// the metered cap is 720p and the fallback bounds are 1080p.
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

    /// nil when nothing would be left. Callers drop the profile rather than
    /// send an empty or absent codec list, either of which Jellyfin reads as
    /// "no constraint" — the opposite of what removal means.
    private static func withoutHEVC(_ codecs: String) -> String? {
        let kept = codecs.split(separator: ",").filter { $0 != "hevc" }
        return kept.isEmpty ? nil : kept.joined(separator: ",")
    }

    #if DEBUG && targetEnvironment(simulator)
    /// CoreSimulator has no reliable HEVC/Dolby Vision hardware decoder.
    /// UI regression tests therefore ask Jellyfin for an H.264/AAC HLS
    /// rendition; production and physical-device profiles remain unchanged.
    static let simulatorRegression = Profile(
        // Keep the generated rendition light enough for deterministic
        // seek tests even when the server must decode a 4K source first.
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
