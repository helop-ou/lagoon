import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil

// HEL-48 M1: thin wrapper over libavformat. All methods must be called on
// the engine's demux queue; nothing here is thread-safe on its own.
//
// FFmpeg imports as raw C: pointers, manual unref, sentinel values. The
// sentinels are redefined locally because their macros don't import.
nonisolated private let avNoPTS = Int64.min // AV_NOPTS_VALUE
nonisolated private let avTimeBase = 1_000_000.0 // AV_TIME_BASE
nonisolated private let seekBackwardFlag: Int32 = 1 // AVSEEK_FLAG_BACKWARD
nonisolated private let keyPacketFlag: Int32 = 1 // AV_PKT_FLAG_KEY
nonisolated private let avErrorEOF: Int32 = -541_478_725 // AVERROR_EOF = -MKTAG('E','O','F',' ')
nonisolated private let customIOFlag: Int32 = 0x0080 // AVFMT_FLAG_CUSTOM_IO

nonisolated enum DemuxError: LocalizedError {
    case openFailed(String)
    case seekFailed(String)
    case unsupportedVideo(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let detail): "The stream could not be opened (\(detail))."
        case .seekFailed(let detail): "The stream could not seek to that position (\(detail))."
        case .unsupportedVideo(let codec): "The Lagoon engine can't decode \(codec) yet."
        }
    }

    /// Whether a different delivery of the same media could help. Opening
    /// and seeking are container and transport problems, which a server-side
    /// remux routinely fixes; an unsupported codec is not.
    var cause: PlaybackEngineFailure.Cause {
        switch self {
        case .openFailed, .seekFailed: .delivery
        case .unsupportedVideo: .undecodable
        }
    }
}

/// AC-3 normally stays compressed through Apple's audio renderer. Alongside
/// Lagoon's software-decoded VC-1 video, however, that path exhibits audible
/// interruptions and sustained MallocHelper growth on tvOS. Decoding only
/// that legacy pairing to LPCM keeps the Jellyfin session Direct Play while
/// preserving E-AC-3/Atmos passthrough for modern media.
nonisolated enum AudioDecodePolicy {
    static func requiresLocalPCM(codecID: AVCodecID, softwareVideoDecoded: Bool) -> Bool {
        softwareVideoDecoded && codecID == AV_CODEC_ID_AC3
    }
}

/// One demuxed stream with everything the render pipeline needs.
nonisolated struct DemuxedStream {
    let streamIndex: Int32
    let codecName: String
    let language: String?
    let title: String?
    let channels: Int
    /// FFmpeg reported the Atmos profile (E-AC3 JOC / TrueHD Atmos) —
    /// surfaces in track names so the JOC track is identifiable.
    let isAtmos: Bool
    /// nil only for subtitle streams — cues render as an overlay, not
    /// through a sample-buffer renderer.
    let formatDescription: CMFormatDescription?
    /// Fallback per-packet duration in seconds for audio packets that
    /// arrive without one (frames-per-packet / sample-rate).
    let fallbackPacketDuration: Double
    /// Video codec reorder lookahead reported by libavformat. Zero for
    /// audio/subtitle streams and video formats without reordered frames.
    let videoReorderDepth: Int
}

nonisolated final class FFmpegDemuxer {
    enum ReadResult {
        case video(CMSampleBuffer)
        case audio([CMSampleBuffer], streamIndex: Int32)
        case subtitle([SubtitleEvent], streamIndex: Int32)
        case skipped
        case endOfFile
        case failed(String)
    }

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private let capabilities: PlaybackCapabilities
    private var cachedIO: FFmpegCachedIO?
    private var hlsCache: HLSPlaybackCacheScope?
    private let childIOLock = NSLock()
    private var childCachedIO: [UInt: (io: FFmpegCachedIO, lease: HLSPlaybackCacheLease)] = [:]
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var videoStreamIndex: Int32 = -1
    private var videoTimeBase = AVRational(num: 1, den: 1)
    private var audioTimeBases: [Int32: AVRational] = [:]
    private var selectedAudioStreamIndex: Int32 = -1
    private var didDrainAudioAtEOF = false
    private var didDrainVideoAtEOF = false
    // M4: codecs CoreAudio can't take compressed decode to LPCM here.
    private var audioDecoders: [Int32: AudioDecoder] = [:]
    private var subtitleDecoders: [Int32: SubtitleDecoder] = [:]
    // HEL-64: sample-exact pts chains for compressed passthrough audio —
    // container timestamps are quantized (Matroska: 1 ms) and the renderer
    // turns every quantization mismatch into an audible discontinuity.
    private var passthroughTimelines: [Int32: PassthroughAudioTimeline] = [:]
    // HEL-64: remove Matroska's millisecond quantization from video PTS.
    // This was not the root cause of the measured 10% HEVC frame loss, but
    // keeps both compressed and decoded presentation timing sample-exact.
    private var videoTimeline: VideoFrameTimeline?
    // Apple exposes no tvOS VideoToolbox decoder for VC-1. The original
    // stream still direct-plays: libavcodec produces ready Core Video frames
    // that enter the same AVFoundation renderer/synchronizer as every other
    // codec.
    private var softwareVideoDecoder: SoftwareVideoDecoder?
    private var pendingDecodedVideo: [CMSampleBuffer] = []

    /// HEL-64 hardware experiment (Settings → Debug): set before `open`.
    /// Only arms when the stream really is single-track DoVi with an
    /// enhancement layer present.
    var stripEnhancementLayer = false
    /// HEL-64 A/B: opt back into marking disposable frames droppable
    /// (4e2ad5f's behavior) — see the factory's attachment comment for
    /// why the default volunteers nothing. Set before `open`.
    var markDroppableFrames = false
    /// Non-nil = stripping armed; demux-queue use only.
    private var videoNALLengthSize: Int?
    // Written per-packet on the demux queue, read by the HUD from the main
    // actor — proof the experiment engaged (the retraction lesson: verify
    // the gate before trusting the A/B).
    private let stripStatsLock = NSLock()
    nonisolated(unsafe) private var stripStats: (units: Int, bytes: Int64)?

    var enhancementLayerStripStats: (units: Int, bytes: Int64)? {
        stripStatsLock.lock()
        defer { stripStatsLock.unlock() }
        return stripStats
    }

    /// Compressed audio packets `PassthroughAudioTimeline` rejected as
    /// overlapping. These never reach a renderer, so `AudioContinuityMonitor`
    /// cannot see them and `aGaps` stays 0 however many are lost — this is
    /// the only place the loss is visible. `worstOverlap` in packet-multiples
    /// is what says which failure it is: under 1 is the boundary repeat the
    /// guard was written for, far above it is a real discontinuity being
    /// muted rather than re-anchored.
    var audioPacketDropStats: (packets: Int, worstOverlapSeconds: Double, packetSeconds: Double)? {
        audioDropLock.lock()
        defer { audioDropLock.unlock() }
        guard audioDroppedPackets > 0 else { return nil }
        return (audioDroppedPackets, worstAudioOverlapSeconds, droppedAudioPacketSeconds)
    }

    private let audioDropLock = NSLock()
    nonisolated(unsafe) private var audioDroppedPackets = 0
    nonisolated(unsafe) private var worstAudioOverlapSeconds: Double = 0
    nonisolated(unsafe) private var droppedAudioPacketSeconds: Double = 0

    private(set) var videoStream: DemuxedStream?
    private(set) var audioStreams: [DemuxedStream] = []
    private(set) var subtitleStreams: [DemuxedStream] = []
    private(set) var durationSeconds: Double = 0
    /// The video stream's best-guess frame rate (display matching wants
    /// it); 0 when FFmpeg can't tell.
    private(set) var videoFrameRate: Double = 0
    /// The pts grid in force, for the HUD's gate check (demux queue only).
    var videoGridDescription: String? {
        softwareVideoDecoder?.gridDescription ?? videoTimeline?.gridDescription
    }
    var outputsDecodedVideo: Bool { softwareVideoDecoder != nil }

    init(capabilities: PlaybackCapabilities = .current) {
        self.capabilities = capabilities
    }

    /// Whether packets remain compressed for an Apple decoder. AV1 only
    /// enters that path when VideoToolbox reports hardware support; otherwise
    /// libdav1d produces P010/NV12 image buffers. VP9 is always software here.
    static func usesCompressedVideoPath(
        codecID: AVCodecID,
        capabilities: PlaybackCapabilities
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC:
            true
        case AV_CODEC_ID_AV1:
            capabilities.hardwareAV1
        default:
            false
        }
    }

    func outputsDecodedAudio(streamIndex: Int32) -> Bool {
        audioDecoders[streamIndex] != nil
    }

    // Written from the main actor at shutdown, polled by FFmpeg's interrupt
    // callback from inside blocked network I/O — this is what guarantees a
    // wedged open/read can't hang teardown.
    private let interruptLock = NSLock()
    nonisolated(unsafe) private var interruptedFlag = false

    var isInterrupted: Bool {
        interruptLock.lock()
        defer { interruptLock.unlock() }
        return interruptedFlag
    }

    func interrupt() {
        interruptLock.lock()
        interruptedFlag = true
        interruptLock.unlock()
    }

    func open(
        url: String,
        cacheSession: PlaybackCacheSession? = nil,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes
    ) throws {
        avformat_network_init()
        guard let allocated = avformat_alloc_context() else {
            throw DemuxError.openFailed("out of memory")
        }
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<FFmpegDemuxer>.fromOpaque(opaque).takeUnretainedValue().isInterrupted ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        if let cacheScope = cacheSession?.directScope {
            let cachedIO = try FFmpegCachedIO(scope: cacheScope)
            allocated.pointee.pb = cachedIO.context
            allocated.pointee.flags |= customIOFlag
            self.cachedIO = cachedIO
        } else if let hlsCache = cacheSession?.hlsScope {
            // libavformat copies `opaque` into nested HLS format contexts.
            // Mutable .m3u8 manifests fall through to avio_open2; immutable
            // media resources get Lagoon AVIO contexts and bounded LRU files.
            self.hlsCache = hlsCache
            allocated.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
            allocated.pointee.io_open = { context, output, url, flags, options in
                guard let context, let opaque = context.pointee.opaque else { return -5 }
                return Unmanaged<FFmpegDemuxer>
                    .fromOpaque(opaque)
                    .takeUnretainedValue()
                    .openChildIO(output: output, url: url, flags: flags, options: options)
            }
            allocated.pointee.io_close2 = { context, ioContext in
                guard let context, let opaque = context.pointee.opaque else { return -5 }
                return Unmanaged<FFmpegDemuxer>
                    .fromOpaque(opaque)
                    .takeUnretainedValue()
                    .closeChildIO(ioContext)
            }
        }

        // Bound every network operation and survive transient drops — an
        // unbounded connect was capable of wedging playback startup.
        var options: OpaquePointer?
        av_dict_set(&options, "rw_timeout", "15000000", 0) // 15 s per I/O op
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        av_dict_set(&options, "reconnect_delay_max", "2", 0)
        if hlsCache != nil {
            // FFmpeg's HLS keep-alive path assumes every segment AVIOContext
            // wraps its native HTTP URLContext. Lagoon deliberately replaces
            // immutable segments with file-backed cached AVIO contexts, so a
            // later segment can otherwise be mistaken for a reusable HTTP
            // connection and trip hls.c's `av_assert0(uc)`. Open each cached
            // segment independently; manifests still use native HTTP I/O.
            av_dict_set(&options, "http_persistent", "0", 0)
        }
        defer { av_dict_free(&options) }

        var ctx: UnsafeMutablePointer<AVFormatContext>? = allocated
        var status = avformat_open_input(&ctx, url, nil, &options)
        guard status >= 0, let ctx else {
            cachedIO?.close()
            cachedIO = nil
            closeAllChildIO()
            hlsCache = nil
            throw DemuxError.openFailed(Self.errorText(status))
        }
        formatContext = ctx
        var completedOpen = false
        defer {
            // Once avformat_open_input succeeds, every later throw owns the
            // context. The demux loop's close path only runs after a complete
            // open, so partial stream/codec setup is cleaned up here.
            if !completedOpen { close() }
        }
        status = avformat_find_stream_info(ctx, nil)
        guard status >= 0 else {
            throw DemuxError.openFailed(Self.errorText(status))
        }

        if ctx.pointee.duration > 0 {
            durationSeconds = Double(ctx.pointee.duration) / avTimeBase
        }

        let bestVideo = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard bestVideo >= 0, let stream = ctx.pointee.streams[Int(bestVideo)] else {
            throw DemuxError.openFailed("no video stream")
        }

        // M6: in an HLS master every variant becomes a program. Restrict
        // the working set to the chosen video's program — otherwise other
        // variants' audio would duplicate the track list and libavformat
        // would keep downloading their segments. Non-HLS files have no
        // programs and pass everything through.
        var programStreams: Set<Int32> = []
        for programIndex in 0..<Int(ctx.pointee.nb_programs) {
            guard let program = ctx.pointee.programs[programIndex] else { continue }
            let members = (0..<Int(program.pointee.nb_stream_indexes)).map {
                Int32(program.pointee.stream_index[$0])
            }
            if members.contains(bestVideo) {
                programStreams = Set(members)
                break
            }
        }
        let videoPar = stream.pointee.codecpar!
        videoStreamIndex = bestVideo
        videoTimeBase = stream.pointee.time_base
        let guessedRate = av_guess_frame_rate(ctx, stream, nil)
        if guessedRate.num > 0, guessedRate.den > 0 {
            videoFrameRate = Double(guessedRate.num) / Double(guessedRate.den)
        }
        let usesCompressedVideo = Self.usesCompressedVideoPath(
            codecID: videoPar.pointee.codec_id,
            capabilities: capabilities
        )
        // A container that describes no parameter sets has to be caught
        // before the description is built, not after: the description is
        // created successfully either way and only the decoder refuses
        // (HEL-131).
        let harvestedParameterSets = usesCompressedVideo
            ? harvestedHEVCParameterSets(ctx: ctx, streamIndex: bestVideo, codecpar: videoPar)
            : nil
        var videoDescription: CMFormatDescription? = if usesCompressedVideo {
            SampleBufferFactory.videoFormatDescription(
                codecpar: videoPar,
                hevcParameterSets: harvestedParameterSets
            )
        } else {
            nil
        }
        if videoDescription == nil, SoftwareVideoDecoder.supports(codecID: videoPar.pointee.codec_id) {
            let decoder = try SoftwareVideoDecoder(
                codecpar: videoPar,
                timeBase: videoTimeBase,
                frameRate: guessedRate,
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
            )
            softwareVideoDecoder = decoder
            videoDescription = decoder.formatDescription
        }
        guard let videoDescription else {
            throw DemuxError.unsupportedVideo(String(cString: avcodec_get_name(videoPar.pointee.codec_id)))
        }
        if softwareVideoDecoder == nil {
            videoTimeline = VideoFrameTimeline(
                frameRateNum: guessedRate.num,
                frameRateDen: guessedRate.den
            )
        }
        if stripEnhancementLayer,
           videoPar.pointee.codec_id == AV_CODEC_ID_HEVC,
           let dovi = SampleBufferFactory.doviConfiguration(codecpar: videoPar),
           dovi.el_present_flag != 0,
           let extradata = videoPar.pointee.extradata, videoPar.pointee.extradata_size > 0,
           let lengthSize = HEVCEnhancementLayerFilter.nalLengthSize(
               hvcc: Data(bytes: extradata, count: Int(videoPar.pointee.extradata_size))
           ) {
            videoNALLengthSize = lengthSize
            stripStatsLock.lock()
            stripStats = (0, 0)
            stripStatsLock.unlock()
        }
        videoStream = DemuxedStream(
            streamIndex: bestVideo,
            codecName: String(cString: avcodec_get_name(videoPar.pointee.codec_id)),
            language: Self.metadata(stream, key: "language"),
            title: Self.metadata(stream, key: "title"),
            channels: 0,
            isAtmos: false,
            formatDescription: videoDescription,
            fallbackPacketDuration: 0,
            videoReorderDepth: Int(videoPar.pointee.video_delay)
        )

        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
            if !programStreams.isEmpty, !programStreams.contains(Int32(index)) {
                stream.pointee.discard = AVDISCARD_ALL
                continue
            }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                // Passthrough codecs wrap compressed; everything else gets
                // a libavcodec → LPCM decoder (M4). Only codecs FFmpeg has
                // no decoder for drop out of the track list.
                var description: CMFormatDescription?
                var fallbackDuration: Double = 0
                let requiresLocalPCM = AudioDecodePolicy.requiresLocalPCM(
                    codecID: par.pointee.codec_id,
                    softwareVideoDecoded: softwareVideoDecoder != nil
                )
                if !requiresLocalPCM,
                   let (passthrough, framesPerPacket) = SampleBufferFactory.audioFormatDescription(codecpar: par) {
                    description = passthrough
                    fallbackDuration = Double(framesPerPacket) / Double(max(par.pointee.sample_rate, 1))
                    passthroughTimelines[Int32(index)] = PassthroughAudioTimeline(
                        sampleRate: par.pointee.sample_rate,
                        framesPerPacket: framesPerPacket
                    )
                } else if let decoder = AudioDecoder(codecpar: par, timeBase: stream.pointee.time_base) {
                    description = decoder.formatDescription
                    audioDecoders[Int32(index)] = decoder
                }
                guard let description else {
                    stream.pointee.discard = AVDISCARD_ALL
                    continue
                }
                audioTimeBases[Int32(index)] = stream.pointee.time_base
                audioStreams.append(DemuxedStream(
                    streamIndex: Int32(index),
                    codecName: String(cString: avcodec_get_name(par.pointee.codec_id)),
                    language: Self.metadata(stream, key: "language"),
                    title: Self.metadata(stream, key: "title"),
                    channels: Int(par.pointee.ch_layout.nb_channels),
                    // AV_PROFILE_EAC3_DDP_ATMOS and AV_PROFILE_TRUEHD_ATMOS
                    // share the value 30.
                    isAtmos: (par.pointee.codec_id == AV_CODEC_ID_EAC3 || par.pointee.codec_id == AV_CODEC_ID_TRUEHD)
                        && par.pointee.profile == 30,
                    formatDescription: description,
                    fallbackPacketDuration: fallbackDuration,
                    videoReorderDepth: 0
                ))
            case AVMEDIA_TYPE_SUBTITLE:
                // Every subtitle stream is listed even when undecodable so
                // the engine's per-type ordinals stay aligned with the
                // server's stream list (M5). Unselected streams stay
                // discarded inside libavformat.
                stream.pointee.discard = AVDISCARD_ALL
                if let decoder = SubtitleDecoder(codecpar: par, timeBase: stream.pointee.time_base) {
                    subtitleDecoders[Int32(index)] = decoder
                }
                subtitleStreams.append(DemuxedStream(
                    streamIndex: Int32(index),
                    codecName: String(cString: avcodec_get_name(par.pointee.codec_id)),
                    language: Self.metadata(stream, key: "language"),
                    title: Self.metadata(stream, key: "title"),
                    channels: 0,
                    isAtmos: false,
                    formatDescription: nil,
                    fallbackPacketDuration: 0,
                    videoReorderDepth: 0
                ))
            case AVMEDIA_TYPE_VIDEO:
                if Int32(index) != bestVideo {
                    stream.pointee.discard = AVDISCARD_ALL
                }
            default:
                stream.pointee.discard = AVDISCARD_ALL
            }
        }

        guard let packet = av_packet_alloc() else {
            throw DemuxError.openFailed("out of memory")
        }
        self.packet = packet
        completedOpen = true
    }

    /// Demux only the chosen audio stream; the rest are discarded inside
    /// libavformat so they never cost a packet copy.
    func selectAudio(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        selectedAudioStreamIndex = streamIndex ?? -1
        for stream in audioStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Same discard dance for the chosen embedded subtitle stream (nil =
    /// subtitles off / an external track is active).
    func selectSubtitle(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        for stream in subtitleStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// How far to read looking for parameter sets. They are the opening
    /// NALs of the first access unit in every file that muxes this way, so
    /// this only has to cover whatever audio and subtitle packets happen to
    /// be interleaved ahead of the first video one.
    private static let parameterSetProbeLimit = 64

    /// VPS, SPS and PPS taken from the bitstream, for an HEVC track whose
    /// container declared none of its own (HEL-131).
    ///
    /// nil in the ordinary case, so a well-formed `hvcC` keeps the existing
    /// path and reads no packets at all. When it does run, the context is
    /// rewound afterwards: the demux loop has not started yet and still owes
    /// the renderer every packet from the beginning.
    private func harvestedHEVCParameterSets(
        ctx: UnsafeMutablePointer<AVFormatContext>,
        streamIndex: Int32,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> [Data]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
              let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else { return nil }
        let hvcc = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        guard !SampleBufferFactory.hevcExtradataCarriesParameterSets(hvcc),
              // The header stays valid even with no arrays behind it, so the
              // NAL length prefix is still described correctly.
              let lengthSize = HEVCEnhancementLayerFilter.nalLengthSize(hvcc: hvcc),
              let probe = av_packet_alloc() else { return nil }
        var owned: UnsafeMutablePointer<AVPacket>? = probe
        defer { av_packet_free(&owned) }

        var sets: [UInt8: Data] = [:]
        var packetsRead = 0
        while packetsRead < Self.parameterSetProbeLimit, sets.count < 3 {
            guard av_read_frame(ctx, probe) >= 0 else { break }
            packetsRead += 1
            if probe.pointee.stream_index == streamIndex, let data = probe.pointee.data {
                Self.collectParameterSets(
                    from: UnsafeRawBufferPointer(start: data, count: Int(probe.pointee.size)),
                    lengthSize: lengthSize,
                    into: &sets
                )
            }
            av_packet_unref(probe)
        }

        // Rewind whether or not the harvest worked. A failure here costs the
        // opening packets, which is worth strictly less than the decoder the
        // harvest buys, so it is not treated as fatal.
        if avformat_seek_file(ctx, streamIndex, Int64.min, 0, 0, 0) < 0 {
            _ = av_seek_frame(ctx, streamIndex, 0, seekBackwardFlag)
        }

        // VPS, SPS, PPS, in the order the decoder expects them.
        let ordered = [32, 33, 34].compactMap { sets[UInt8($0)] }
        return ordered.count == 3 ? ordered : nil
    }

    /// Walks one length-prefixed packet, keeping the first of each
    /// parameter-set NAL it finds.
    private static func collectParameterSets(
        from payload: UnsafeRawBufferPointer,
        lengthSize: Int,
        into sets: inout [UInt8: Data]
    ) {
        guard let base = payload.baseAddress, (1...4).contains(lengthSize) else { return }
        let count = payload.count
        var offset = 0
        while offset + lengthSize <= count {
            var nalLength = 0
            for index in 0..<lengthSize {
                nalLength = nalLength << 8 | Int(payload[offset + index])
            }
            let start = offset + lengthSize
            let end = start + nalLength
            guard nalLength > 0, end <= count else { return }
            let nalType = (payload[start] >> 1) & 0x3F
            if (32...34).contains(nalType), sets[nalType] == nil {
                sets[nalType] = Data(bytes: base.advanced(by: start), count: nalLength)
            }
            offset = end
        }
    }

    func seek(toSeconds seconds: Double) throws {
        guard let ctx = formatContext else {
            throw DemuxError.seekFailed("demuxer not open")
        }
        // Anchor the request in the selected video stream's clock. HLS can
        // expose a separate audio rendition as its default stream; seeking
        // with stream_index -1 then moves audio correctly while video keeps
        // reading from its prior playlist position.
        let timestamp = Int64(
            seconds * Double(videoTimeBase.den) / Double(max(videoTimeBase.num, 1))
        )
        // The legacy single-stream seek can leave split HLS audio/video
        // inputs at different playlist positions (observed as a full audio
        // queue and zero video after a backward scrub). The newer API seeks
        // all active streams to a jointly presentable point. Constraining
        // max_ts to the requested time still gives decoders the keyframe at
        // or before the target. Keep the legacy call as a compatibility
        // fallback for demuxers that do not implement avformat_seek_file.
        var status = avformat_seek_file(
            ctx,
            videoStreamIndex,
            Int64.min,
            timestamp,
            timestamp,
            0
        )
        if status < 0 {
            status = av_seek_frame(ctx, videoStreamIndex, timestamp, seekBackwardFlag)
        }
        try Self.validateSeekStatus(status)
        cachedIO?.setTimelineAnchor(seconds: seconds, duration: durationSeconds)
        didDrainAudioAtEOF = false
        didDrainVideoAtEOF = false
        pendingDecodedVideo.removeAll(keepingCapacity: true)
        for decoder in audioDecoders.values {
            decoder.flush()
        }
        for index in passthroughTimelines.keys {
            passthroughTimelines[index]?.reset()
        }
        videoTimeline?.reset()
        softwareVideoDecoder?.flush()
        for decoder in subtitleDecoders.values {
            decoder.flush()
        }
    }

    static func validateSeekStatus(_ status: Int32) throws {
        guard status >= 0 else {
            throw DemuxError.seekFailed(errorText(status))
        }
    }

    func readNext() -> ReadResult {
        guard let ctx = formatContext, let packet else { return .failed("demuxer not open") }
        if !pendingDecodedVideo.isEmpty {
            return .video(pendingDecodedVideo.removeFirst())
        }
        var status = av_read_frame(ctx, packet)
        // M6: only AVERROR_EOF means the stream ended. Anything else is a
        // read failure — retry briefly (the avio reconnect options handle
        // the socket; this covers errors that surface past them), then
        // report it instead of silently ending playback mid-file.
        var attempts = 0
        while status < 0, status != avErrorEOF, !isInterrupted, attempts < 2 {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.2 * Double(attempts))
            status = av_read_frame(ctx, packet)
        }
        if status == avErrorEOF || isInterrupted {
            // Drain delayed B-frames before ending the video queue. VC-1's
            // libavcodec decoder normally retains pictures at EOF.
            if !didDrainVideoAtEOF {
                didDrainVideoAtEOF = true
                do {
                    pendingDecodedVideo = try softwareVideoDecoder?.drain() ?? []
                } catch {
                    return .failed(error.localizedDescription)
                }
                if !pendingDecodedVideo.isEmpty {
                    return .video(pendingDecodedVideo.removeFirst())
                }
            }
            // Hand the audio decoder's tail (coalesced partial buffer) to the
            // renderer before declaring the end.
            if !didDrainAudioAtEOF {
                didDrainAudioAtEOF = true
                if selectedAudioStreamIndex >= 0,
                   let decoder = audioDecoders[selectedAudioStreamIndex] {
                    let tail = decoder.drain()
                    if !tail.isEmpty {
                        return .audio(tail, streamIndex: selectedAudioStreamIndex)
                    }
                }
            }
            return .endOfFile
        }
        if status < 0 {
            return .failed(Self.errorText(status))
        }
        defer { av_packet_unref(packet) }
        let streamIndex = packet.pointee.stream_index

        if streamIndex == videoStreamIndex {
            let timestamp = packet.pointee.pts != avNoPTS
                ? packet.pointee.pts
                : packet.pointee.dts
            if timestamp != avNoPTS {
                let seconds = Double(timestamp)
                    * Double(videoTimeBase.num) / Double(max(videoTimeBase.den, 1))
                cachedIO?.setTimelineAnchor(
                    byteOffset: packet.pointee.pos,
                    seconds: seconds,
                    duration: durationSeconds
                )
            }
        }

        if streamIndex == videoStreamIndex, let softwareVideoDecoder {
            do {
                pendingDecodedVideo = try softwareVideoDecoder.decode(packet: packet)
            } catch {
                return .failed(error.localizedDescription)
            }
            return pendingDecodedVideo.isEmpty
                ? .skipped
                : .video(pendingDecodedVideo.removeFirst())
        }
        if streamIndex == videoStreamIndex, let description = videoStream?.formatDescription {
            var strippedPayload: Data?
            if let lengthSize = videoNALLengthSize, let data = packet.pointee.data {
                strippedPayload = HEVCEnhancementLayerFilter.strippingEnhancementLayer(
                    from: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
                    lengthSize: lengthSize
                )
                if let strippedPayload {
                    stripStatsLock.lock()
                    var stats = stripStats ?? (0, 0)
                    stats.units += 1
                    stats.bytes += Int64(Int(packet.pointee.size) - strippedPayload.count)
                    stripStats = stats
                    stripStatsLock.unlock()
                }
            }
            // Snap the presentation stamp onto the exact frame grid;
            // decode stamps stay the container's (ordering only).
            var timing: CMSampleTimingInfo?
            if videoTimeline != nil, packet.pointee.pts != avNoPTS {
                let containerSeconds = Double(packet.pointee.pts)
                    * Double(videoTimeBase.num) / Double(max(videoTimeBase.den, 1))
                if let snapped = videoTimeline!.snapped(containerSeconds: containerSeconds) {
                    let scaledDTS = packet.pointee.dts == avNoPTS
                        ? nil
                        : packet.pointee.dts.multipliedReportingOverflow(by: Int64(videoTimeBase.num))
                    let dts: CMTime = if let scaledDTS, !scaledDTS.overflow {
                        CMTime(value: scaledDTS.partialValue, timescale: max(videoTimeBase.den, 1))
                    } else {
                        .invalid
                    }
                    timing = CMSampleTimingInfo(
                        duration: videoTimeline!.frameDuration,
                        presentationTimeStamp: snapped,
                        decodeTimeStamp: dts
                    )
                }
            }
            guard let buffer = SampleBufferFactory.sampleBuffer(
                packet: packet,
                formatDescription: description,
                timeBase: videoTimeBase,
                isVideo: true,
                fallbackDuration: 0,
                isKeyFrame: packet.pointee.flags & keyPacketFlag != 0,
                timingOverride: timing,
                payloadOverride: strippedPayload,
                markDroppableFrames: markDroppableFrames
            ) else { return .skipped }
            return .video(buffer)
        }
        if let decoder = audioDecoders[streamIndex] {
            let buffers = decoder.decode(packet: packet)
            return buffers.isEmpty ? .skipped : .audio(buffers, streamIndex: streamIndex)
        }
        if let audio = audioStreams.first(where: { $0.streamIndex == streamIndex }),
           let description = audio.formatDescription,
           let timeBase = audioTimeBases[streamIndex] {
            // Sample-exact pts for passthrough audio (HEL-64) — the
            // container's quantized stamp only anchors the chain.
            let ptsValue = packet.pointee.pts != avNoPTS ? packet.pointee.pts : packet.pointee.dts
            let containerSeconds: Double? = ptsValue == avNoPTS
                ? nil
                : Double(ptsValue) * Double(timeBase.num) / Double(max(timeBase.den, 1))
            let timing = passthroughTimelines[streamIndex]?.timing(containerSeconds: containerSeconds)
            if let timeline = passthroughTimelines[streamIndex], timeline.lastPacketWasOverlapping {
                audioDropLock.lock()
                audioDroppedPackets += 1
                worstAudioOverlapSeconds = max(worstAudioOverlapSeconds, timeline.lastOverlapSeconds)
                droppedAudioPacketSeconds = timeline.packetSeconds
                audioDropLock.unlock()
                return .skipped
            }
            guard let buffer = SampleBufferFactory.sampleBuffer(
                packet: packet,
                formatDescription: description,
                timeBase: timeBase,
                isVideo: false,
                fallbackDuration: audio.fallbackPacketDuration,
                isKeyFrame: true,
                timingOverride: timing
            ) else { return .skipped }
            return .audio([buffer], streamIndex: streamIndex)
        }
        if let decoder = subtitleDecoders[streamIndex] {
            let events = decoder.decode(packet: packet)
            return events.isEmpty ? .skipped : .subtitle(events, streamIndex: streamIndex)
        }
        return .skipped
    }

    func close() {
        if packet != nil {
            av_packet_free(&packet)
        }
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        cachedIO?.close()
        cachedIO = nil
        closeAllChildIO()
        hlsCache = nil

        // These wrappers free AVCodecContext/SWR resources in deinit.
        // close() runs on the demux queue; clearing them here prevents that
        // C teardown from being deferred until the main-actor engine is
        // released after dismissal (HEL-57).
        audioDecoders.removeAll(keepingCapacity: false)
        subtitleDecoders.removeAll(keepingCapacity: false)
        softwareVideoDecoder = nil
        pendingDecodedVideo.removeAll(keepingCapacity: false)
        audioStreams.removeAll(keepingCapacity: false)
        subtitleStreams.removeAll(keepingCapacity: false)
        videoStream = nil
    }

    private func openChildIO(
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
        url: UnsafePointer<CChar>?,
        flags: Int32,
        options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32 {
        guard let output, let url else { return -22 }
        let nativeOpen = {
            avio_open2(output, url, flags, nil, options)
        }
        guard flags & 1 != 0, flags & 2 == 0,
              let hlsCache,
              let resourceURL = URL(string: String(cString: url)) else {
            return nativeOpen()
        }
        do {
            guard let lease = try hlsCache.leaseResource(at: resourceURL) else {
                return nativeOpen()
            }
            // FFmpeg holds several segment contexts open at once, and a
            // whole segment fits under the per-resource cap, so these keep the
            // small buffer: there is no unstorable-read case to amortize here.
            let io = try FFmpegCachedIO(scope: lease.scope, bufferSize: 64 * 1_024)
            guard let context = io.context else {
                lease.close()
                return nativeOpen()
            }
            childIOLock.lock()
            childCachedIO[UInt(bitPattern: context)] = (io, lease)
            childIOLock.unlock()
            output.pointee = context
            return 0
        } catch {
            // Cache failure must never make an otherwise playable HLS stream
            // fail. FFmpeg retains its native reconnect/timeout behavior.
            return nativeOpen()
        }
    }

    private func closeChildIO(_ context: UnsafeMutablePointer<AVIOContext>?) -> Int32 {
        guard let context else { return 0 }
        childIOLock.lock()
        let cached = childCachedIO.removeValue(forKey: UInt(bitPattern: context))
        childIOLock.unlock()
        if let cached {
            cached.io.close()
            cached.lease.close()
            return 0
        }
        var nativeContext: UnsafeMutablePointer<AVIOContext>? = context
        return avio_closep(&nativeContext)
    }

    private func closeAllChildIO() {
        childIOLock.lock()
        let cached = Array(childCachedIO.values)
        childCachedIO.removeAll(keepingCapacity: false)
        childIOLock.unlock()
        for resource in cached {
            resource.io.close()
            resource.lease.close()
        }
    }

    private static func metadata(_ stream: UnsafeMutablePointer<AVStream>, key: String) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0),
              let value = entry.pointee.value else { return nil }
        return String(cString: value)
    }

    private static func errorText(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
