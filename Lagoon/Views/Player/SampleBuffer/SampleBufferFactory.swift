import AudioToolbox
import CoreMedia
import Foundation
import Libavcodec
import Libavutil

nonisolated private let avNoPTS = Int64.min // AV_NOPTS_VALUE

/// Turns FFmpeg codec parameters and packets into the CoreMedia objects the
/// AVSampleBuffer* renderers eat (HEL-48 M1).
///
/// The trick that makes the whole architecture cheap: Matroska stores
/// h264/hevc exactly like mp4 (avcC/hvcC extradata, length-prefixed NALs),
/// so demuxed packets can be wrapped as compressed CMSampleBuffers and the
/// display layer decodes them itself — no VTDecompressionSession needed.
/// Same for aac/ac3/eac3 audio: CoreAudio decodes the compressed packets
/// handed to AVSampleBufferAudioRenderer.
nonisolated enum SampleBufferFactory {
    static func videoFormatDescription(codecpar: UnsafeMutablePointer<AVCodecParameters>) -> CMFormatDescription? {
        let codecType: CMVideoCodecType
        let atomKey: String
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_H264:
            codecType = kCMVideoCodecType_H264
            atomKey = "avcC"
        case AV_CODEC_ID_HEVC:
            codecType = kCMVideoCodecType_HEVC
            atomKey = "hvcC"
        default:
            return nil
        }
        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
            return nil
        }
        let configurationRecord = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atomKey: configurationRecord],
        ]
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: codecpar.pointee.width,
            height: codecpar.pointee.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// Returns the description plus the codec's frames-per-packet (for
    /// fallback durations). aac needs its AudioSpecificConfig as the magic
    /// cookie; ac3/eac3 are self-describing.
    static func audioFormatDescription(codecpar: UnsafeMutablePointer<AVCodecParameters>) -> (CMFormatDescription, framesPerPacket: Int)? {
        let formatID: AudioFormatID
        let framesPerPacket: Int
        var cookie: Data?
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_AAC:
            formatID = kAudioFormatMPEG4AAC
            framesPerPacket = 1024
            if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
                cookie = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            }
        case AV_CODEC_ID_AC3:
            formatID = kAudioFormatAC3
            framesPerPacket = 1536
        case AV_CODEC_ID_EAC3:
            formatID = kAudioFormatEnhancedAC3
            framesPerPacket = 1536
        default:
            return nil
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(codecpar.pointee.sample_rate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(codecpar.pointee.ch_layout.nb_channels, 1)),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var description: CMFormatDescription?
        let status: OSStatus
        if let cookie {
            status = cookie.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: cookie.count,
                    magicCookie: bytes.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { return nil }
        return (description, framesPerPacket)
    }

    /// Wraps one demuxed packet as a compressed CMSampleBuffer. Video keeps
    /// decode timestamps (packets arrive in decode order; the layer
    /// reorders B-frames from the timing info) and marks non-keyframes
    /// NotSync so post-seek behavior is correct.
    static func sampleBuffer(
        packet: UnsafeMutablePointer<AVPacket>,
        formatDescription: CMFormatDescription,
        timeBase: AVRational,
        isVideo: Bool,
        fallbackDuration: Double,
        isKeyFrame: Bool
    ) -> CMSampleBuffer? {
        guard let data = packet.pointee.data else { return nil }
        let size = Int(packet.pointee.size)
        guard size > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: size,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        guard CMBlockBufferReplaceDataBytes(
            with: data,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: size
        ) == noErr else { return nil }

        let secondsPerUnit = Double(timeBase.num) / Double(max(timeBase.den, 1))
        func time(_ value: Int64) -> CMTime {
            value == avNoPTS ? .invalid : CMTime(seconds: Double(value) * secondsPerUnit, preferredTimescale: 90_000)
        }
        let presentation = packet.pointee.pts != avNoPTS ? time(packet.pointee.pts) : time(packet.pointee.dts)
        let duration: CMTime = if packet.pointee.duration > 0 {
            CMTime(seconds: Double(packet.pointee.duration) * secondsPerUnit, preferredTimescale: 90_000)
        } else if fallbackDuration > 0 {
            CMTime(seconds: fallbackDuration, preferredTimescale: 90_000)
        } else {
            .invalid
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentation,
            decodeTimeStamp: isVideo ? time(packet.pointee.dts) : .invalid
        )

        var sampleSize = size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if isVideo, !isKeyFrame,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
