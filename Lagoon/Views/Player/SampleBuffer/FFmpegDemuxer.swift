import CoreMedia
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

nonisolated enum DemuxError: LocalizedError {
    case openFailed(String)
    case unsupportedVideo(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let detail): "The stream could not be opened (\(detail))."
        case .unsupportedVideo(let codec): "The Lagoon engine can't decode \(codec) yet."
        }
    }
}

/// One demuxed stream with everything the render pipeline needs.
nonisolated struct DemuxedStream {
    let streamIndex: Int32
    let codecName: String
    let language: String?
    let title: String?
    let channels: Int
    let formatDescription: CMFormatDescription
    /// Fallback per-packet duration in seconds for audio packets that
    /// arrive without one (frames-per-packet / sample-rate).
    let fallbackPacketDuration: Double
}

nonisolated final class FFmpegDemuxer {
    enum ReadResult {
        case video(CMSampleBuffer)
        case audio(CMSampleBuffer, streamIndex: Int32)
        case skipped
        case endOfFile
        case failed(String)
    }

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var videoStreamIndex: Int32 = -1
    private var videoTimeBase = AVRational(num: 1, den: 1)
    private var audioTimeBases: [Int32: AVRational] = [:]

    private(set) var videoStream: DemuxedStream?
    private(set) var audioStreams: [DemuxedStream] = []
    private(set) var durationSeconds: Double = 0

    func open(url: String) throws {
        avformat_network_init()
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        var status = avformat_open_input(&ctx, url, nil, nil)
        guard status >= 0, let ctx else {
            throw DemuxError.openFailed(Self.errorText(status))
        }
        formatContext = ctx
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
        let videoPar = stream.pointee.codecpar!
        guard let videoDescription = SampleBufferFactory.videoFormatDescription(codecpar: videoPar) else {
            throw DemuxError.unsupportedVideo(String(cString: avcodec_get_name(videoPar.pointee.codec_id)))
        }
        videoStreamIndex = bestVideo
        videoTimeBase = stream.pointee.time_base
        videoStream = DemuxedStream(
            streamIndex: bestVideo,
            codecName: String(cString: avcodec_get_name(videoPar.pointee.codec_id)),
            language: Self.metadata(stream, key: "language"),
            title: Self.metadata(stream, key: "title"),
            channels: 0,
            formatDescription: videoDescription,
            fallbackPacketDuration: 0
        )

        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                // Streams whose codec we can't wrap yet stay out of the
                // track list entirely — the engine's canPlay() gate should
                // have kept those files on mpv anyway.
                guard let (description, framesPerPacket) = SampleBufferFactory.audioFormatDescription(codecpar: par) else {
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
                    formatDescription: description,
                    fallbackPacketDuration: Double(framesPerPacket) / Double(max(par.pointee.sample_rate, 1))
                ))
            case AVMEDIA_TYPE_VIDEO:
                if Int32(index) != bestVideo {
                    stream.pointee.discard = AVDISCARD_ALL
                }
            default:
                stream.pointee.discard = AVDISCARD_ALL
            }
        }

        packet = av_packet_alloc()
    }

    /// Demux only the chosen audio stream; the rest are discarded inside
    /// libavformat so they never cost a packet copy.
    func selectAudio(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        for stream in audioStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    func seek(toSeconds seconds: Double) {
        guard let ctx = formatContext else { return }
        av_seek_frame(ctx, -1, Int64(seconds * avTimeBase), seekBackwardFlag)
    }

    func readNext() -> ReadResult {
        guard let ctx = formatContext, let packet else { return .failed("demuxer not open") }
        let status = av_read_frame(ctx, packet)
        if status < 0 {
            // AVERROR_EOF or read failure; both end the stream for M1.
            return .endOfFile
        }
        defer { av_packet_unref(packet) }
        let streamIndex = packet.pointee.stream_index

        if streamIndex == videoStreamIndex, let videoStream {
            guard let buffer = SampleBufferFactory.sampleBuffer(
                packet: packet,
                formatDescription: videoStream.formatDescription,
                timeBase: videoTimeBase,
                isVideo: true,
                fallbackDuration: 0,
                isKeyFrame: packet.pointee.flags & keyPacketFlag != 0
            ) else { return .skipped }
            return .video(buffer)
        }
        if let audio = audioStreams.first(where: { $0.streamIndex == streamIndex }),
           let timeBase = audioTimeBases[streamIndex] {
            guard let buffer = SampleBufferFactory.sampleBuffer(
                packet: packet,
                formatDescription: audio.formatDescription,
                timeBase: timeBase,
                isVideo: false,
                fallbackDuration: audio.fallbackPacketDuration,
                isKeyFrame: true
            ) else { return .skipped }
            return .audio(buffer, streamIndex: streamIndex)
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
