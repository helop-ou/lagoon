import CoreMedia
import CoreVideo
import VideoToolbox
import Foundation
import Libavcodec
import Libavutil
import _LagoonFFmpeg

/// Software video fallback for codecs Apple does not expose through
/// VideoToolbox — VC-1/WMV3, MPEG-4 Part 2 (the Xvid/DivX envelope AVI
/// rips carry), progressive MPEG-2, VP9, and AV1 on devices without an AV1
/// hardware decoder. Each is decoded by Lagoon's pinned libavcodec, copied into
/// renderer-recommended Core Video buffers, and wrapped as ready image sample
/// buffers. AVFoundation still owns presentation, color conversion, A/V sync,
/// display matching, and output.
///
/// The accepted output is deliberately narrow: 8-bit planar/NV12 becomes
/// NV12, while little-endian 10-bit planar/P010 becomes Core Video P010.
/// Anything else fails closed instead of silently presenting incorrect color.
nonisolated final class SoftwareVideoDecoder: @unchecked Sendable {
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
                "The software video decoder could not start (\(detail))."
            case .pixelBufferPool(let status):
                "Core Video could not create the software decode frame pool (\(status))."
            case .pixelBuffer(let status):
                "Core Video could not allocate a software-decoded frame (\(status))."
            case .unsupportedPixelFormat(let format):
                "The software video decoder produced an unsupported pixel format (\(format))."
            case .outputFormat(let status):
                "Core Media could not describe a software-decoded frame (\(status))."
            case .outputSample(let status):
                "Core Media could not wrap a software-decoded frame (\(status))."
            case .decode(let status):
                "The software video decoder failed (\(status))."
            }
        }
    }

    private struct ColorProperties {
        let primaries: CFString?
        let transfer: CFString?
        let matrix: CFString?
        let chromaLocation: CFString?
        /// HDR10 static metadata. The compressed path puts these straight
        /// into the format description; here they have to travel as buffer
        /// attachments, because the description is derived from a pixel
        /// buffer rather than built by hand.
        let masteringDisplay: Data?
        let contentLightLevel: Data?
        let ambientViewingEnvironment: Data?

        var isHDR: Bool {
            transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }

        /// What the frame is tagged as after the hardware tone-maps it to
        /// SDR: BT.709 end to end, no HDR metadata to mislead the display.
        var sdrToneMapped: ColorProperties {
            ColorProperties(
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                chromaLocation: chromaLocation,
                masteringDisplay: nil,
                contentLightLevel: nil,
                ambientViewingEnvironment: nil
            )
        }
    }

    private let codecContext: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let timeBase: AVRational
    private let width: Int
    private let height: Int
    private let outputBitDepth: Int
    private let pixelBufferPool: CVPixelBufferPool
    /// Non-nil when frames leave here in Apple's lossless-compressed tiled
    /// format rather than as linear planes (HEL-137).
    ///
    /// The display engine will not scan out a linear surface: measured with
    /// the renderer's `optimized` counter, VideoToolbox's compressed frames
    /// detach at 87% while every linear frame this pool produced composited
    /// on the GPU — about 20 ms of a 41.7 ms frame budget at 4K, more than
    /// decoding costs. `VTPixelTransferSession` is the hardware block that
    /// converts into that format; probed once at open, and if the probe fails
    /// the linear path continues exactly as before.
    private let transferSession: VTPixelTransferSession?
    private let compressedPool: CVPixelBufferPool?
    /// What the frames leaving this decoder are tagged as. Identical to
    /// `colorProperties` except on tvOS for HDR sources, where it is the
    /// BT.709 result of the hardware tone map (HEL-137).
    private let outputProperties: ColorProperties
    /// True when HDR content leaves here as tone-mapped SDR — Infuse's
    /// behaviour on Apple TV, adopted for the same reason Firecore gives:
    /// "true HDR output is not available for AV1 videos on the Apple TV".
    /// Mechanically: HDR-signalled surfaces never take the display engine's
    /// direct path on this hardware (measured 0% against 87% for SDR, even
    /// for hardware-decoded Dolby Vision), and the 4K HDR composition that
    /// forces costs about 20 ms of a 41.7 ms frame budget on the same
    /// silicon the CPU decoder needs. SDR output detaches at 88% and gives
    /// the budget back.
    let outputsToneMappedSDR: Bool
    private let colorProperties: ColorProperties
    private let pixelAspectRatio: (horizontal: Int32, vertical: Int32)?
    private var timeline: VideoFrameTimeline?
    private let profileLock = NSLock()
    private var profileStorage = Profile()
    private var profileStartedAt: Double?
    /// Rolling window, so the HUD can show what the decoder is managing now
    /// rather than an average dragged up by a fast start (HEL-137).
    private var windowStartedAt: Double?
    private var windowFrames = 0
    private static let windowSeconds = 2.0

    let formatDescription: CMVideoFormatDescription
    var gridDescription: String? { timeline?.gridDescription }

    /// Threads libavcodec settled on after opening, which is not necessarily
    /// what it was asked for: zero means auto and the resolved value is only
    /// legible here (HEL-137).
    let resolvedThreadCount: Int32

    /// Where the software path's time actually goes (HEL-137), separated so
    /// nobody has to guess which stage is the expensive one. Cumulative since
    /// the last flush, which is every seek — the same boundary the frame-loss
    /// bench re-arms on, so a bench window and this profile describe the same
    /// stretch of playback.
    ///
    /// `decodeSeconds` is libavcodec (dav1d and its worker threads bill their
    /// own time elsewhere, so on a threaded decoder this is the wait, not the
    /// work). `conversionSeconds` is everything between a decoded AVFrame and
    /// a ready `CMSampleBuffer`: the Core Video allocation, the 10-bit shift
    /// and chroma interleave, the attachments. Both are wall time on the
    /// decode queue, so as a fraction of `elapsedSeconds` they read as the
    /// share of one core this stage holds.
    struct Profile: Equatable, Sendable {
        var frames = 0
        var packets = 0
        var decodeSeconds = 0.0
        var conversionSeconds = 0.0
        /// Of the conversion, getting a surface to write into rather than
        /// writing to it. Measured at 0.06 ms on an Apple TV: the pool
        /// recycles, so allocation is not a cost worth chasing.
        var surfaceSeconds = 0.0
        var elapsedSeconds = 0.0
        /// Frames per second over the last completed rolling window, rather
        /// than since the seek. See `recentFramesPerSecond`.
        var recentFramesPerSecond = 0.0

        /// Frames per second since the last seek.
        ///
        /// **This cannot tell a healthy pipeline from a struggling one**, and
        /// two builds of HEL-137 were read wrongly because of it. Once the
        /// queues fill, backpressure throttles the decoder to playback rate,
        /// so a decoder with headroom to spare and one with none both settle
        /// here at the frame rate of the content. Read `decodeMilliseconds`
        /// for capacity and `recentFramesPerSecond` for what is happening now.
        var framesPerSecond: Double {
            elapsedSeconds > 0 ? Double(frames) / elapsedSeconds : 0
        }

        /// What one frame costs libavcodec, in milliseconds.
        ///
        /// The number that actually answers "does this device have the
        /// headroom", because unlike a rate it does not move when the decoder
        /// is deliberately held back. Compare against the frame budget: 41.7 ms
        /// at 23.976 fps.
        var decodeMilliseconds: Double {
            frames > 0 ? decodeSeconds / Double(frames) * 1_000 : 0
        }

        /// What one frame costs to turn into a renderer surface, in
        /// milliseconds.
        var conversionMilliseconds: Double {
            frames > 0 ? conversionSeconds / Double(frames) * 1_000 : 0
        }

        /// Of that, acquiring and locking the destination surface.
        var surfaceMilliseconds: Double {
            frames > 0 ? surfaceSeconds / Double(frames) * 1_000 : 0
        }

        /// Everything a frame costs this stage, which is what has to fit
        /// inside a frame period. Reporting decode alone read 76% of budget
        /// while the real total was over 100%, and hid the conversion for
        /// four builds (HEL-137).
        var frameMilliseconds: Double {
            decodeMilliseconds + conversionMilliseconds
        }

        /// Share of one core spent inside libavcodec.
        var decodeFraction: Double {
            elapsedSeconds > 0 ? decodeSeconds / elapsedSeconds : 0
        }

        /// Share of one core spent turning frames into renderer surfaces.
        var conversionFraction: Double {
            elapsedSeconds > 0 ? conversionSeconds / elapsedSeconds : 0
        }

        /// How much of a frame period the decoder is using, where 1.0 is
        /// exactly keeping up and nothing above it can hold frame rate.
        func decodeBudgetUsed(frameRate: Double) -> Double {
            guard frameRate > 0, frameMilliseconds > 0 else { return 0 }
            return frameMilliseconds / (1_000 / frameRate)
        }
    }

    /// Bytes one decoded surface occupies, for the queue limit that has to
    /// bound them (HEL-137 lever 5; a 4K P010 frame is 23.7 MiB).
    var decodedFrameBytes: Int64 {
        DecodedFrameMemory.bytesPer420Frame(
            width: width,
            height: height,
            bitDepth: outputBitDepth
        )
    }

    var profile: Profile {
        profileLock.withLock { profileStorage }
    }

    static func supports(codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_VC1
            || codecID == AV_CODEC_ID_WMV3
            || codecID == AV_CODEC_ID_MPEG4
            || codecID == AV_CODEC_ID_MPEG2VIDEO
            || codecID == AV_CODEC_ID_AV1
            || codecID == AV_CODEC_ID_VP9
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
        // Decode on every core the device has. libavcodec's own default here
        // is one thread, not auto, which left dav1d decoding 4K AV1 on a
        // single core while the rest of the SoC idled: 30 s of 3840x2160
        // AV1 measured 13.26 s of decode single-threaded against 1.66 s with
        // this set, on the same machine. Zero means auto-detect, so each
        // decoder takes what it can use and one that cannot thread at all
        // ignores it. `thread_type` already defaults to frame and slice
        // threading together, so it is left alone.
        //
        // Safe with the rest of this class as written: `drain()` already
        // flushes the delay frame threading introduces, and `flush()` resets
        // the decoder on every seek.
        //
        // HEL-137 added the one alternative worth measuring behind a toggle:
        // a count bounded to the performance cluster, for the case where
        // frame threading across an A15's four efficiency cores costs more in
        // synchronisation than it returns. Off, this stays zero.
        context.pointee.thread_count = SoftwareDecodeThreadPolicy.resolvedThreadCount()
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

        let probedPixelFormat = AVPixelFormat(rawValue: codecpar.pointee.format)
        let contextPixelFormat = context.pointee.pix_fmt
        let sourcePixelFormat = probedPixelFormat == AV_PIX_FMT_NONE
            ? contextPixelFormat
            : probedPixelFormat
        guard let resolvedBitDepth = Self.outputBitDepth(
            pixelFormat: sourcePixelFormat,
            bitsPerRawSample: codecpar.pointee.bits_per_raw_sample,
            bitsPerCodedSample: codecpar.pointee.bits_per_coded_sample,
            codecID: codecpar.pointee.codec_id
        ) else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            let name = av_get_pix_fmt_name(sourcePixelFormat).map(String.init(cString:))
                ?? "pixel-format \(sourcePixelFormat.rawValue)"
            throw DecoderError.codecSetup("unsupported \(name)")
        }
        let fullRange = codecpar.pointee.color_range == AVCOL_RANGE_JPEG
        let outputPixelFormat: OSType = if resolvedBitDepth == 10 {
            fullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            fullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        var attributes = VideoToolboxDecoder.resolvedPixelBufferAttributes(
            recommended: recommendedPixelBufferAttributes
        ).rawAttributes
        attributes[kCVPixelBufferWidthKey as String] = resolvedWidth
        attributes[kCVPixelBufferHeightKey as String] = resolvedHeight
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = outputPixelFormat
        // Without this the surface cannot be wrapped as a Metal texture and
        // the GPU conversion silently falls back to the CPU for every frame.
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        // What VideoToolbox's own surfaces carry and ours never did: the flag
        // that lets Core Animation hand the surface to the display engine
        // instead of compositing it on the GPU. Measured with the HUD's
        // `optimized` counter: VT frames detach at 87%, ours at 0%, and the
        // composition costs ~20 ms of a 41.7 ms frame budget (HEL-137).
        attributes[kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey as String] = true
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

        // The transfer function is what puts tvOS into HDR; the primaries and
        // matrix are left alone so the colour is as close as it can be without
        // tone mapping (HEL-137). Dropping the static metadata with it keeps
        // the display from being told about a master it is no longer being
        // shown in.
        let properties = ColorProperties(
            primaries: SampleBufferFactory.colorPrimaries(codecpar.pointee.color_primaries),
            transfer: SampleBufferFactory.transferFunction(codecpar.pointee.color_trc),
            matrix: SampleBufferFactory.yCbCrMatrix(codecpar.pointee.color_space),
            chromaLocation: SampleBufferFactory.chromaLocation(codecpar.pointee.chroma_location),
            masteringDisplay: SampleBufferFactory.masteringDisplayColorVolume(codecpar),
            contentLightLevel: SampleBufferFactory.contentLightLevel(codecpar),
            ambientViewingEnvironment: SampleBufferFactory.ambientViewingEnvironment(codecpar)
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
        let aspect = SampleBufferFactory.pixelAspectRatio(codecpar.pointee.sample_aspect_ratio)
        Self.apply(properties, pixelAspectRatio: aspect, to: prototype)

        // Whether HDR leaves here as SDR. tvOS only: an iPhone screen shows
        // EDR content well and pays composition it can afford, while the
        // Apple TV cannot scan out an HDR surface from this path at all.
        #if os(tvOS)
        let wantsToneMappedSDR = properties.isHDR
        #else
        let wantsToneMappedSDR = false
        #endif

        // The compressed output stage: a session, a pool in the lossless
        // format, and one probe transfer so a configuration the hardware
        // refuses falls back to linear before anything is advertised. The
        // same pass tone-maps to SDR where that was decided above: the
        // session's destination properties tell the hardware what to convert
        // to, and it does the colour math along with the tiling.
        var compressedSetup: (VTPixelTransferSession, CVPixelBufferPool, CVPixelBuffer)?
        if UserDefaults.standard.object(forKey: "debug.softwareDecodeCompressedOutput") as? Bool ?? true {
            let compressedFormat: OSType = resolvedBitDepth == 10
                ? kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
                : kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
            let compressedAttributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: resolvedWidth,
                kCVPixelBufferHeightKey as String: resolvedHeight,
                kCVPixelBufferPixelFormatTypeKey as String: compressedFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var sessionOut: VTPixelTransferSession?
            var poolOut: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 18] as CFDictionary,
                compressedAttributes as CFDictionary,
                &poolOut
            )
            if let poolOut,
               VTPixelTransferSessionCreate(
                   allocator: kCFAllocatorDefault,
                   pixelTransferSessionOut: &sessionOut
               ) == noErr,
               let sessionOut {
                var sessionUsable = true
                if wantsToneMappedSDR {
                    let destination: [(CFString, CFString)] = [
                        (kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                         kCVImageBufferColorPrimaries_ITU_R_709_2),
                        (kVTPixelTransferPropertyKey_DestinationTransferFunction,
                         kCVImageBufferTransferFunction_ITU_R_709_2),
                        (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                    ]
                    for (key, value) in destination
                    where VTSessionSetProperty(sessionOut, key: key, value: value) != noErr {
                        sessionUsable = false
                    }
                }
                var probe: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &probe)
                if sessionUsable,
                   let probe,
                   VTPixelTransferSessionTransferImage(sessionOut, from: prototype, to: probe) == noErr {
                    compressedSetup = (sessionOut, poolOut, probe)
                }
            }
        }
        let resolvedOutputProperties = compressedSetup != nil && wantsToneMappedSDR
            ? properties.sdrToneMapped
            : properties
        if let probe = compressedSetup?.2 {
            Self.apply(resolvedOutputProperties, pixelAspectRatio: aspect, to: probe)
        }

        let descriptionSource = compressedSetup?.2 ?? prototype
        var description: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: descriptionSource,
            formatDescriptionOut: &description
        )
        guard descriptionStatus == noErr, let description else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.outputFormat(descriptionStatus)
        }

        transferSession = compressedSetup?.0
        compressedPool = compressedSetup?.1
        outputProperties = resolvedOutputProperties
        outputsToneMappedSDR = compressedSetup != nil && wantsToneMappedSDR
        codecContext = context
        resolvedThreadCount = context.pointee.thread_count
        frame = decodedFrame
        self.timeBase = timeBase
        width = resolvedWidth
        height = resolvedHeight
        outputBitDepth = resolvedBitDepth
        pixelBufferPool = createdPool
        colorProperties = properties
        pixelAspectRatio = aspect
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
        let sent = Self.now()
        beginProfileIfNeeded(at: sent)
        let status = avcodec_send_packet(codecContext, packet)
        let elapsed = Self.now()
        recordProfile(at: elapsed) {
            $0.packets += 1
            $0.decodeSeconds += elapsed - sent
        }
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
        // A seek starts a new stretch of playback, which is also the boundary
        // the frame-loss bench re-arms on. Averaging across one would mix two
        // scenes into a single number, and the whole point of the profile is
        // that it describes the scene the bench is measuring.
        profileLock.withLock {
            profileStorage = Profile()
            profileStartedAt = nil
            windowStartedAt = nil
            windowFrames = 0
        }
    }

    private func receiveFrames() throws -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        while true {
            let waited = Self.now()
            let status = avcodec_receive_frame(codecContext, frame)
            let received = Self.now()
            recordProfile(at: received) { $0.decodeSeconds += received - waited }
            guard status >= 0 else { break }
            defer { av_frame_unref(frame) }
            let buffer = try makeSampleBuffer()
            let converted = Self.now()
            recordProfile(at: converted) {
                $0.frames += 1
                $0.conversionSeconds += converted - received
            }
            output.append(buffer)
        }
        return output
    }

    /// Monotonic and cheap; `ProcessInfo.systemUptime` reads the same mach
    /// timebase the signposts do.
    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private func beginProfileIfNeeded(at instant: Double) {
        profileLock.withLock {
            if profileStartedAt == nil { profileStartedAt = instant }
        }
    }

    private func recordProfile(at instant: Double, _ body: (inout Profile) -> Void) {
        profileLock.withLock {
            let before = profileStorage.frames
            body(&profileStorage)
            if let start = profileStartedAt {
                profileStorage.elapsedSeconds = instant - start
            }
            guard profileStorage.frames > before else { return }
            windowFrames += profileStorage.frames - before
            guard let windowStart = windowStartedAt else {
                windowStartedAt = instant
                return
            }
            let span = instant - windowStart
            guard span >= Self.windowSeconds else { return }
            profileStorage.recentFramesPerSecond = Double(windowFrames) / span
            windowStartedAt = instant
            windowFrames = 0
        }
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
        let decodedFormat = AVPixelFormat(rawValue: frame.pointee.format)
        let isSupported8Bit = outputBitDepth == 8 && (
            decodedFormat == AV_PIX_FMT_YUV420P
                || decodedFormat == AV_PIX_FMT_YUVJ420P
                || decodedFormat == AV_PIX_FMT_NV12
        )
        let isSupported10Bit = outputBitDepth == 10 && (
            decodedFormat == AV_PIX_FMT_YUV420P10LE
                || decodedFormat == AV_PIX_FMT_P010LE
        )
        guard isSupported8Bit || isSupported10Bit,
              Int(frame.pointee.width) == width,
              Int(frame.pointee.height) == height else {
            let name = av_get_pix_fmt_name(decodedFormat).map(String.init(cString:)) ?? "\(frame.pointee.format)"
            throw DecoderError.unsupportedPixelFormat(name)
        }

        // An interlaced frame is made progressive before it is copied out,
        // so nothing downstream ever sees a field pair (HEL-127). Ten-bit
        // formats are left alone: interlaced content at that depth is not
        // something this engine has met, and guessing at one is worse than
        // the transcode the profile still asks for.
        if isSupported8Bit, frame.pointee.flags & Self.interlacedFrameFlag != 0 {
            deinterlaceInPlace(decodedFormat: decodedFormat)
        }

        let surfaceStart = Self.now()
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
        let surfaceAcquired = Self.now()
        profileLock.withLock { profileStorage.surfaceSeconds += surfaceAcquired - surfaceStart }

        guard let sourceY = planePointer(0),
              let destinationY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let destinationUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw DecoderError.unsupportedPixelFormat("missing image planes")
        }
        if decodedFormat == AV_PIX_FMT_YUV420P10LE {
            Self.shift10BitPlaneToP010(
                source: UnsafeRawPointer(sourceY).assumingMemoryBound(to: UInt16.self),
                sourceStride: planeStride(0),
                destination: UnsafeMutableRawPointer(destinationY).assumingMemoryBound(to: UInt16.self),
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                width: width,
                rows: height
            )
            guard let sourceU = planePointer(1), let sourceV = planePointer(2) else {
                throw DecoderError.unsupportedPixelFormat("missing 10-bit planar chroma")
            }
            Self.interleave420Chroma10BitToP010(
                sourceU: UnsafeRawPointer(sourceU).assumingMemoryBound(to: UInt16.self),
                sourceUStride: planeStride(1),
                sourceV: UnsafeRawPointer(sourceV).assumingMemoryBound(to: UInt16.self),
                sourceVStride: planeStride(2),
                destination: UnsafeMutableRawPointer(destinationUV).assumingMemoryBound(to: UInt16.self),
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                width: width,
                rows: height / 2
            )
        } else if decodedFormat == AV_PIX_FMT_P010LE {
            guard let sourceUV = planePointer(1) else {
                throw DecoderError.unsupportedPixelFormat("missing P010 chroma plane")
            }
            Self.copyRows(
                source: sourceY,
                sourceStride: planeStride(0),
                destination: destinationY,
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                rowBytes: width * MemoryLayout<UInt16>.stride,
                rows: height
            )
            Self.copyRows(
                source: sourceUV,
                sourceStride: planeStride(1),
                destination: destinationUV,
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                rowBytes: width * MemoryLayout<UInt16>.stride,
                rows: height / 2
            )
        } else {
            Self.copyRows(
                source: sourceY,
                sourceStride: planeStride(0),
                destination: destinationY,
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                rowBytes: width,
                rows: height
            )
        }

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
        } else if decodedFormat == AV_PIX_FMT_YUV420P || decodedFormat == AV_PIX_FMT_YUVJ420P {
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
        Self.apply(colorProperties, pixelAspectRatio: pixelAspectRatio, to: pixelBuffer)

        return try makeReadySample(from: finished(pixelBuffer), timing: resolvedTiming())
    }

    /// The linear surface, or the compressed copy of it the display engine
    /// can take without compositing (HEL-137). The transfer is one pass of a
    /// fixed-function block, synchronous, and does not touch the CPU beyond
    /// issuing it; the linear buffer goes straight back to its pool.
    private func finished(_ linear: CVPixelBuffer) -> CVPixelBuffer {
        guard let transferSession, let compressedPool else { return linear }
        var compressed: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, compressedPool, &compressed
        ) == kCVReturnSuccess, let compressed else { return linear }
        let surfaceStart = Self.now()
        guard VTPixelTransferSessionTransferImage(
            transferSession, from: linear, to: compressed
        ) == noErr else { return linear }
        let surfaceEnd = Self.now()
        profileLock.withLock { profileStorage.surfaceSeconds += surfaceEnd - surfaceStart }
        Self.apply(outputProperties, pixelAspectRatio: pixelAspectRatio, to: compressed)
        return compressed
    }

    /// Presentation timing for the frame the decoder is holding. Resolved
    /// before the pixels are converted, so the CPU and GPU paths hand the same
    /// stamps to the renderer.
    private func resolvedTiming() -> CMSampleTimingInfo {
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
        return CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
    }

    private func makeReadySample(
        from pixelBuffer: CVPixelBuffer,
        timing: CMSampleTimingInfo
    ) throws -> CMSampleBuffer {
        var timing = timing
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

    /// libavutil declares these as macros, which do not reach Swift.
    private static let interlacedFrameFlag: Int32 = 1 << 3
    private static let topFieldFirstFlag: Int32 = 1 << 4

    /// Deinterlaces the decoded frame in place, before it is copied out.
    ///
    /// Only the software path has this. It is where MPEG-2 is decoded and so
    /// where DVD lives; the hardware path has no deinterlacing stage, which is
    /// why the device profile still asks the server to handle interlaced
    /// content in every other codec (HEL-127).
    ///
    /// The frame is made writable first. What the decoder handed over may
    /// still be a reference frame that later pictures are predicted from, and
    /// editing that in place would corrupt everything that follows it.
    private func deinterlaceInPlace(decodedFormat: AVPixelFormat) {
        guard av_frame_make_writable(frame) >= 0 else { return }
        let topFieldFirst = frame.pointee.flags & Self.topFieldFirstFlag != 0
        guard let luma = planePointer(0) else { return }
        Deinterlacer.plane(
            base: UnsafeMutablePointer(mutating: luma),
            stride: planeStride(0),
            width: width,
            height: height,
            keepingTopField: topFieldFirst
        )
        if decodedFormat == AV_PIX_FMT_NV12 {
            guard let chroma = planePointer(1) else { return }
            // Interleaved chroma: a prediction steps two bytes at a time so
            // it never mixes a U sample with a V one.
            Deinterlacer.plane(
                base: UnsafeMutablePointer(mutating: chroma),
                stride: planeStride(1),
                width: width,
                height: height / 2,
                componentStride: 2,
                keepingTopField: topFieldFirst
            )
            return
        }
        for plane in 1...2 {
            guard let chroma = planePointer(plane) else { return }
            Deinterlacer.plane(
                base: UnsafeMutablePointer(mutating: chroma),
                stride: planeStride(plane),
                width: width / 2,
                height: height / 2,
                keepingTopField: topFieldFirst
            )
        }
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

    /// Resolves the storage contract before Core Video creates its fixed-format
    /// pool. Stream probing normally supplies the pixel format; the bit-depth
    /// fields cover containers that only declare depth. Legacy codecs are
    /// intrinsically 8-bit inside Lagoon's advertised envelope.
    static func outputBitDepth(
        pixelFormat: AVPixelFormat,
        bitsPerRawSample: Int32,
        bitsPerCodedSample: Int32,
        codecID: AVCodecID
    ) -> Int? {
        switch pixelFormat {
        case AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_NV12:
            return 8
        case AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_P010LE:
            return 10
        default:
            let declared = bitsPerRawSample > 0 ? bitsPerRawSample : bitsPerCodedSample
            if declared > 0, declared <= 8 { return 8 }
            if declared > 8, declared <= 10 { return 10 }
            if codecID == AV_CODEC_ID_VC1
                || codecID == AV_CODEC_ID_WMV3
                || codecID == AV_CODEC_ID_MPEG4
                || codecID == AV_CODEC_ID_MPEG2VIDEO {
                return 8
            }
            return nil
        }
    }

    /// Splits a plane's rows across cores.
    ///
    /// The primitives below are NEON but single-threaded. Row ranges are
    /// independent — each reads row `n` of the source and writes row `n` of
    /// the destination — so this needs no coordination beyond the split, and a
    /// negative stride is not a special case: the caller has already pointed
    /// the base at the last row, and advancing by `start * stride` walks
    /// backwards from there exactly as the serial loop does.
    ///
    /// Worth 0.5 ms of a 4.8 ms conversion on an Apple TV, measured. Only that
    /// much because the copy is bounded by memory bandwidth rather than by
    /// cores. Chunks stay well below the core count for the same reason the
    /// gain is small: these threads compete with dav1d's (HEL-137).
    private static let conversionChunks: Int = {
        let override = UserDefaults.standard.integer(forKey: "debug.softwareDecodeConvertChunks")
        if override > 0 { return min(override, 8) }
        return min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1), 3)
    }()

    static func parallelRows(_ rows: Int, _ body: (_ start: Int, _ count: Int) -> Void) {
        // Below a few hundred rows the split costs more than it saves.
        let chunks = min(conversionChunks, max(rows / 128, 1))
        guard chunks > 1 else {
            body(0, rows)
            return
        }
        let perChunk = (rows + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let start = index * perChunk
            guard start < rows else { return }
            body(start, min(perChunk, rows - start))
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
        parallelRows(rows) { start, count in
            LagoonPixelConversion.interleave420Chroma(
                sourceU: firstU.advanced(by: start * sourceUStride),
                sourceUStride: sourceUStride,
                sourceV: firstV.advanced(by: start * sourceVStride),
                sourceVStride: sourceVStride,
                destination: destination.advanced(by: start * destinationStride),
                destinationStride: destinationStride,
                width: width,
                rows: count
            )
        }
    }

    static func shift10BitPlaneToP010(
        source: UnsafePointer<UInt16>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        let firstSource: UnsafePointer<UInt16> = if sourceStride >= 0 {
            source
        } else {
            UnsafeRawPointer(source)
                .advanced(by: (rows - 1) * -sourceStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        parallelRows(rows) { start, count in
            LagoonPixelConversion.shift10BitPlaneToP010(
                source: UnsafeRawPointer(firstSource)
                    .advanced(by: start * sourceStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceStride: sourceStride,
                destination: UnsafeMutableRawPointer(destination)
                    .advanced(by: start * destinationStride)
                    .assumingMemoryBound(to: UInt16.self),
                destinationStride: destinationStride,
                width: width,
                rows: count
            )
        }
    }

    static func interleave420Chroma10BitToP010(
        sourceU: UnsafePointer<UInt16>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt16>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        let firstU: UnsafePointer<UInt16> = if sourceUStride >= 0 {
            sourceU
        } else {
            UnsafeRawPointer(sourceU)
                .advanced(by: (rows - 1) * -sourceUStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        let firstV: UnsafePointer<UInt16> = if sourceVStride >= 0 {
            sourceV
        } else {
            UnsafeRawPointer(sourceV)
                .advanced(by: (rows - 1) * -sourceVStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        parallelRows(rows) { start, count in
            LagoonPixelConversion.interleave420Chroma10BitToP010(
                sourceU: UnsafeRawPointer(firstU)
                    .advanced(by: start * sourceUStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceUStride: sourceUStride,
                sourceV: UnsafeRawPointer(firstV)
                    .advanced(by: start * sourceVStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceVStride: sourceVStride,
                destination: UnsafeMutableRawPointer(destination)
                    .advanced(by: start * destinationStride)
                    .assumingMemoryBound(to: UInt16.self),
                destinationStride: destinationStride,
                width: width,
                rows: count
            )
        }
    }

    private static func apply(
        _ properties: ColorProperties,
        pixelAspectRatio: (horizontal: Int32, vertical: Int32)?,
        to pixelBuffer: CVPixelBuffer
    ) {
        if let pixelAspectRatio {
            // `CMVideoFormatDescriptionCreateForImageBuffer` reads this back
            // off the buffer, so the description built from the prototype
            // carries the same geometry the compressed path advertises.
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferPixelAspectRatioKey,
                [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey: pixelAspectRatio.horizontal,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: pixelAspectRatio.vertical,
                ] as CFDictionary,
                .shouldPropagate
            )
        }
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
        // HDR10 static metadata. The transfer function alone is what switches
        // tvOS into HDR, but without these the display tone-maps from its own
        // defaults instead of the master's — and the codecs that reach this
        // path (VP9 always, AV1 wherever there is no hardware decoder) are
        // advertised for HDR10/HLG/HDR10+ in `DeviceProfile`.
        //
        // `CMVideoFormatDescriptionCreateForImageBuffer` copies propagated
        // attachments into the description's extensions, and these three
        // CVBuffer keys are the same strings as their CMFormatDescription
        // counterparts, so the prototype carries them into the format
        // description and every decoded frame carries them to the renderer.
        if let masteringDisplay = properties.masteringDisplay {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                masteringDisplay as CFData,
                .shouldPropagate
            )
        }
        if let contentLightLevel = properties.contentLightLevel {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                contentLightLevel as CFData,
                .shouldPropagate
            )
        }
        if let ambientViewingEnvironment = properties.ambientViewingEnvironment {
            // Apple TN3145: custom sample-buffer playback has to carry `amve`
            // through to presentation for correct HDR adaptation.
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferAmbientViewingEnvironmentKey,
                ambientViewingEnvironment as CFData,
                .shouldPropagate
            )
        }
    }
}
