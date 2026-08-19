import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavutil
import _LagoonFFmpeg

/// Software video fallback for codecs Apple does not expose through
/// VideoToolbox. VC-1 is decoded by Lagoon's pinned libavcodec, copied into
/// renderer-recommended Core Video buffers, and wrapped as ready image sample
/// buffers. AVFoundation still owns presentation, color conversion, A/V sync,
/// display matching, and output.
///
/// This intentionally supports only the 8-bit 4:2:0 output VC-1 produces for
/// Lagoon's advertised progressive 1080p envelope. A different decoded pixel
/// format fails closed instead of silently presenting incorrect color.
nonisolated final class SoftwareVideoDecoder {
    enum DecoderError: LocalizedError {
        case codecSetup(String)
        case pixelBufferPool(OSStatus)
        case pixelBuffer(OSStatus)
        case unsupportedPixelFormat(String)
        case outputFormat(OSStatus)
        case outputSample(OSStatus)
        case decode(Int32)

        var errorDescription: String? {
            switch self {
            case .codecSetup(let detail):
                "The VC-1 software decoder could not start (\(detail))."
            case .pixelBufferPool(let status):
                "Core Video could not create the VC-1 frame pool (\(status))."
            case .pixelBuffer(let status):
                "Core Video could not allocate a VC-1 frame (\(status))."
            case .unsupportedPixelFormat(let format):
                "The VC-1 decoder produced an unsupported pixel format (\(format))."
            case .outputFormat(let status):
                "Core Media could not describe a decoded VC-1 frame (\(status))."
            case .outputSample(let status):
                "Core Media could not wrap a decoded VC-1 frame (\(status))."
            case .decode(let status):
                "The VC-1 software decoder failed (\(status))."
            }
        }
    }

    private struct ColorProperties {
        let primaries: CFString?
        let transfer: CFString?
        let matrix: CFString?
        let chromaLocation: CFString?
    }

    private let codecContext: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let timeBase: AVRational
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let pixelBufferPool: CVPixelBufferPool
    private let colorProperties: ColorProperties
    private var timeline: VideoFrameTimeline?

    let formatDescription: CMVideoFormatDescription
    var gridDescription: String? { timeline?.gridDescription }

    static func supports(codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_VC1 || codecID == AV_CODEC_ID_WMV3
    }

    init(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        timeBase: AVRational,
        frameRate: AVRational,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes
    ) throws {
        guard Self.supports(codecID: codecpar.pointee.codec_id),
              let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else {
            throw DecoderError.codecSetup("decoder unavailable")
        }
        guard avcodec_parameters_to_context(context, codecpar) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw DecoderError.codecSetup("invalid codec parameters")
        }
        context.pointee.pkt_timebase = timeBase
        guard avcodec_open2(context, codec, nil) >= 0, let decodedFrame = av_frame_alloc() else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw DecoderError.codecSetup("libavcodec rejected the stream")
        }

        let resolvedWidth = Int(codecpar.pointee.width)
        let resolvedHeight = Int(codecpar.pointee.height)
        guard resolvedWidth > 0, resolvedHeight > 0,
              resolvedWidth.isMultiple(of: 2), resolvedHeight.isMultiple(of: 2) else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.codecSetup("invalid frame dimensions")
        }

        let outputPixelFormat: OSType = codecpar.pointee.color_range == AVCOL_RANGE_JPEG
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var attributes = VideoToolboxDecoder.resolvedPixelBufferAttributes(
            recommended: recommendedPixelBufferAttributes
        ).rawAttributes
        attributes[kCVPixelBufferWidthKey as String] = resolvedWidth
        attributes[kCVPixelBufferHeightKey as String] = resolvedHeight
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = outputPixelFormat
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 18,
        ]

        var createdPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &createdPool
        )
        guard poolStatus == kCVReturnSuccess, let createdPool else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.pixelBufferPool(poolStatus)
        }

        let properties = ColorProperties(
            primaries: SampleBufferFactory.colorPrimaries(codecpar.pointee.color_primaries),
            transfer: SampleBufferFactory.transferFunction(codecpar.pointee.color_trc),
            matrix: SampleBufferFactory.yCbCrMatrix(codecpar.pointee.color_space),
            chromaLocation: SampleBufferFactory.chromaLocation(codecpar.pointee.chroma_location)
        )
        var prototype: CVPixelBuffer?
        let prototypeStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            createdPool,
            &prototype
        )
        guard prototypeStatus == kCVReturnSuccess, let prototype else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.pixelBuffer(prototypeStatus)
        }
        Self.apply(properties, to: prototype)
        var description: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: prototype,
            formatDescriptionOut: &description
        )
        guard descriptionStatus == noErr, let description else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.outputFormat(descriptionStatus)
        }

        codecContext = context
        frame = decodedFrame
        self.timeBase = timeBase
        width = resolvedWidth
        height = resolvedHeight
        pixelFormat = outputPixelFormat
        pixelBufferPool = createdPool
        colorProperties = properties
        timeline = VideoFrameTimeline(
            frameRateNum: frameRate.num,
            frameRateDen: frameRate.den
        )
        formatDescription = description
    }

    deinit {
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&framePointer)
        var contextPointer: UnsafeMutablePointer<AVCodecContext>? = codecContext
        avcodec_free_context(&contextPointer)
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) throws -> [CMSampleBuffer] {
        let status = avcodec_send_packet(codecContext, packet)
        guard status >= 0 else { throw DecoderError.decode(status) }
        return try receiveFrames()
    }

    func drain() throws -> [CMSampleBuffer] {
        let status = avcodec_send_packet(codecContext, nil)
        guard status >= 0 else { throw DecoderError.decode(status) }
        return try receiveFrames()
    }

    func flush() {
        avcodec_flush_buffers(codecContext)
        timeline?.reset()
    }

    private func receiveFrames() throws -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        while avcodec_receive_frame(codecContext, frame) >= 0 {
            defer { av_frame_unref(frame) }
            output.append(try makeSampleBuffer())
        }
        return output
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
        let decodedFormat = AVPixelFormat(rawValue: frame.pointee.format)
        guard decodedFormat == AV_PIX_FMT_YUV420P
                || decodedFormat == AV_PIX_FMT_YUVJ420P
                || decodedFormat == AV_PIX_FMT_NV12,
              Int(frame.pointee.width) == width,
              Int(frame.pointee.height) == height else {
            let name = av_get_pix_fmt_name(decodedFormat).map(String.init(cString:)) ?? "\(frame.pointee.format)"
            throw DecoderError.unsupportedPixelFormat(name)
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw DecoderError.pixelBuffer(pixelStatus)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let sourceY = planePointer(0),
              let destinationY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let destinationUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw DecoderError.unsupportedPixelFormat("missing image planes")
        }
        Self.copyRows(
            source: sourceY,
            sourceStride: planeStride(0),
            destination: destinationY,
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
            rowBytes: width,
            rows: height
        )

        if decodedFormat == AV_PIX_FMT_NV12 {
            guard let sourceUV = planePointer(1) else {
                throw DecoderError.unsupportedPixelFormat("missing NV12 chroma plane")
            }
            Self.copyRows(
                source: sourceUV,
                sourceStride: planeStride(1),
                destination: destinationUV,
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                rowBytes: width,
                rows: height / 2
            )
        } else {
            guard let sourceU = planePointer(1), let sourceV = planePointer(2) else {
                throw DecoderError.unsupportedPixelFormat("missing planar chroma")
            }
            Self.interleave420Chroma(
                sourceU: sourceU,
                sourceUStride: planeStride(1),
                sourceV: sourceV,
                sourceVStride: planeStride(2),
                destination: destinationUV,
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                width: width,
                rows: height / 2
            )
        }
        Self.apply(colorProperties, to: pixelBuffer)

        let rawPTS = frame.pointee.best_effort_timestamp != Int64.min
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        let containerSeconds: Double? = rawPTS == Int64.min
            ? nil
            : Double(rawPTS) * Double(timeBase.num) / Double(max(timeBase.den, 1))
        let exactPTS: CMTime = if let containerSeconds {
            CMTime(seconds: containerSeconds, preferredTimescale: max(timeBase.den, 1))
        } else {
            .invalid
        }
        let presentationTime = containerSeconds.flatMap { timeline?.snapped(containerSeconds: $0) }
            ?? exactPTS
        let duration: CMTime = if let timeline {
            timeline.frameDuration
        } else if frame.pointee.duration > 0 {
            CMTime(
                value: frame.pointee.duration * Int64(timeBase.num),
                timescale: max(timeBase.den, 1)
            )
        } else {
            .invalid
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        guard sampleStatus == noErr, let output else {
            throw DecoderError.outputSample(sampleStatus)
        }
        return output
    }

    private func planePointer(_ index: Int) -> UnsafePointer<UInt8>? {
        withUnsafePointer(to: frame.pointee.data) { tuple in
            UnsafeRawPointer(tuple)
                .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)[index]
                .map { UnsafePointer($0) }
        }
    }

    private func planeStride(_ index: Int) -> Int {
        withUnsafePointer(to: frame.pointee.linesize) { tuple in
            Int(UnsafeRawPointer(tuple).assumingMemoryBound(to: Int32.self)[index])
        }
    }

    static func copyRows(
        source: UnsafePointer<UInt8>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        rowBytes: Int,
        rows: Int
    ) {
        let firstSource = sourceStride >= 0
            ? source
            : source.advanced(by: (rows - 1) * -sourceStride)
        for row in 0..<rows {
            memcpy(
                destination.advanced(by: row * destinationStride),
                firstSource.advanced(by: row * sourceStride),
                rowBytes
            )
        }
    }

    static func interleave420Chroma(
        sourceU: UnsafePointer<UInt8>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt8>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        let firstU = sourceUStride >= 0
            ? sourceU
            : sourceU.advanced(by: (rows - 1) * -sourceUStride)
        let firstV = sourceVStride >= 0
            ? sourceV
            : sourceV.advanced(by: (rows - 1) * -sourceVStride)
        LagoonPixelConversion.interleave420Chroma(
            sourceU: firstU,
            sourceUStride: sourceUStride,
            sourceV: firstV,
            sourceVStride: sourceVStride,
            destination: destination,
            destinationStride: destinationStride,
            width: width,
            rows: rows
        )
    }

    private static func apply(_ properties: ColorProperties, to pixelBuffer: CVPixelBuffer) {
        if let primaries = properties.primaries {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                primaries,
                .shouldPropagate
            )
        }
        if let transfer = properties.transfer {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                transfer,
                .shouldPropagate
            )
        }
        if let matrix = properties.matrix {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                matrix,
                .shouldPropagate
            )
        }
        if let chromaLocation = properties.chromaLocation {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationTopFieldKey,
                chromaLocation,
                .shouldPropagate
            )
        }
    }
}
