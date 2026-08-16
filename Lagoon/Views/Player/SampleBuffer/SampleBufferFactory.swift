import AudioToolbox
import CoreMedia
import Foundation
import Libavcodec
import Libavutil

nonisolated private let avNoPTS = Int64.min // AV_NOPTS_VALUE
nonisolated private let eac3AtmosProfile: Int32 = 30 // AV_PROFILE_EAC3_DDP_ATMOS

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
        var codecType: CMVideoCodecType
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
        var atoms: [String: Data] = [
            atomKey: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size)),
        ]
        var extensions: [CFString: Any] = [:]

        // HEL-48 M3: colorimetry tags. The display pipeline only engages
        // HDR/EDR when the format description declares what the bitstream
        // carries — untagged BT.2020+PQ renders as washed-out SDR.
        if let primaries = colorPrimaries(codecpar.pointee.color_primaries) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let transfer = transferFunction(codecpar.pointee.color_trc) {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let matrix = yCbCrMatrix(codecpar.pointee.color_space) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
        }
        if let chromaLocation = chromaLocation(codecpar.pointee.chroma_location) {
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = chromaLocation
        }
        switch codecpar.pointee.color_range {
        case AVCOL_RANGE_JPEG:
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = kCFBooleanTrue
        case AVCOL_RANGE_MPEG:
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = kCFBooleanFalse
        default:
            break
        }
        if let masteringDisplay = masteringDisplayColorVolume(codecpar) {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplay
        }
        if let contentLight = contentLightLevel(codecpar) {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLight
        }

        // Dolby Vision, single-layer profiles only. Profile 5 (IPTPQc2) is
        // meaningless without the DoVi decode path, so the sample entry
        // itself becomes dvh1; profile 8 keeps hvc1 with a supplementary
        // dvvC so non-DoVi displays fall back to the base layer's
        // HDR10/HLG/SDR tags. Dual-layer profiles (4/7) get no atom — the
        // enhancement layer isn't fed, so the base layer plays as HDR10
        // via the tags above.
        if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
           let dovi: AVDOVIDecoderConfigurationRecord = sideData(codecpar, type: AV_PKT_DATA_DOVI_CONF) {
            switch dovi.dv_profile {
            case 5:
                codecType = kCMVideoCodecType_DolbyVisionHEVC
                atoms["dvcC"] = doviConfigurationBox(dovi)
            case 8:
                atoms["dvvC"] = doviConfigurationBox(dovi)
            default:
                break
            }
        }

        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
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
        var layoutTag: AudioChannelLayoutTag?
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
            // M2 hardware finding: untagged E-AC3 decodes as plain
            // multichannel ("Multichannel" in the AirPods menu, no Atmos).
            // The JOC layer only engages when the channel layout declares
            // Atmos — the tag matching Apple's own 16/JOC signalling.
            if codecpar.pointee.profile == eac3AtmosProfile {
                layoutTag = kAudioChannelLayoutTag_Atmos_9_1_6
            }
        case AV_CODEC_ID_MP3:
            formatID = kAudioFormatMPEGLayer3
            framesPerPacket = 1152
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

        var layout = AudioChannelLayout()
        if let layoutTag {
            layout.mChannelLayoutTag = layoutTag
        }
        var description: CMFormatDescription?
        let status: OSStatus = withUnsafePointer(to: layout) { layoutPointer in
            (cookie ?? Data()).withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: layoutTag != nil ? MemoryLayout<AudioChannelLayout>.size : 0,
                    layout: layoutTag != nil ? layoutPointer : nil,
                    magicCookieSize: cookie?.count ?? 0,
                    magicCookie: cookie != nil ? bytes.baseAddress : nil,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
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

    // MARK: - HDR / Dolby Vision tagging (HEL-48 M3)

    private static func colorPrimaries(_ primaries: AVColorPrimaries) -> CFString? {
        switch primaries {
        case AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCMFormatDescriptionColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE431: kCMFormatDescriptionColorPrimaries_DCI_P3
        case AVCOL_PRI_SMPTE432: kCMFormatDescriptionColorPrimaries_P3_D65
        default: nil
        }
    }

    private static func transferFunction(_ transfer: AVColorTransferCharacteristic) -> CFString? {
        switch transfer {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M: kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: kCMFormatDescriptionTransferFunction_ITU_R_2020
        case AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_IEC61966_2_1: kCMFormatDescriptionTransferFunction_sRGB
        case AVCOL_TRC_LINEAR: kCMFormatDescriptionTransferFunction_Linear
        default: nil
        }
    }

    private static func yCbCrMatrix(_ space: AVColorSpace) -> CFString? {
        switch space {
        case AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: nil
        }
    }

    private static func chromaLocation(_ location: AVChromaLocation) -> CFString? {
        switch location {
        case AVCHROMA_LOC_LEFT: kCMFormatDescriptionChromaLocation_Left
        case AVCHROMA_LOC_CENTER: kCMFormatDescriptionChromaLocation_Center
        case AVCHROMA_LOC_TOPLEFT: kCMFormatDescriptionChromaLocation_TopLeft
        case AVCHROMA_LOC_TOP: kCMFormatDescriptionChromaLocation_Top
        case AVCHROMA_LOC_BOTTOMLEFT: kCMFormatDescriptionChromaLocation_BottomLeft
        case AVCHROMA_LOC_BOTTOM: kCMFormatDescriptionChromaLocation_Bottom
        default: nil
        }
    }

    /// Reads one typed side-data entry off the codec parameters (FFmpeg
    /// stores container-level HDR/DoVi metadata there after
    /// avformat_find_stream_info).
    private static func sideData<T>(_ codecpar: UnsafeMutablePointer<AVCodecParameters>, type: AVPacketSideDataType) -> T? {
        guard let entry = av_packet_side_data_get(
            codecpar.pointee.coded_side_data,
            codecpar.pointee.nb_coded_side_data,
            type
        ), let data = entry.pointee.data, entry.pointee.size >= MemoryLayout<T>.size else {
            return nil
        }
        return UnsafeRawPointer(data).loadUnaligned(as: T.self)
    }

    /// Serializes AVMasteringDisplayMetadata as the 24-byte big-endian
    /// payload CoreMedia expects (SEI mastering_display_colour_volume /
    /// mdcv box): primaries in G,B,R order at 0.00002 steps, luminance at
    /// 0.0001 cd/m².
    private static func masteringDisplayColorVolume(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Data? {
        guard let metadata: AVMasteringDisplayMetadata = sideData(codecpar, type: AV_PKT_DATA_MASTERING_DISPLAY_METADATA),
              metadata.has_primaries != 0, metadata.has_luminance != 0 else {
            return nil
        }
        let chromaticitySteps: Int64 = 50_000
        let luminanceSteps: Int64 = 10_000
        var payload = Data(capacity: 24)
        for primary in [metadata.display_primaries.1, metadata.display_primaries.2, metadata.display_primaries.0] {
            append(UInt16(clamping: rescale(primary.0, by: chromaticitySteps)), to: &payload)
            append(UInt16(clamping: rescale(primary.1, by: chromaticitySteps)), to: &payload)
        }
        append(UInt16(clamping: rescale(metadata.white_point.0, by: chromaticitySteps)), to: &payload)
        append(UInt16(clamping: rescale(metadata.white_point.1, by: chromaticitySteps)), to: &payload)
        append(UInt32(clamping: rescale(metadata.max_luminance, by: luminanceSteps)), to: &payload)
        append(UInt32(clamping: rescale(metadata.min_luminance, by: luminanceSteps)), to: &payload)
        return payload
    }

    /// 4-byte big-endian MaxCLL + MaxFALL (SEI content_light_level_info /
    /// clli box).
    private static func contentLightLevel(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Data? {
        guard let metadata: AVContentLightMetadata = sideData(codecpar, type: AV_PKT_DATA_CONTENT_LIGHT_LEVEL),
              metadata.MaxCLL > 0 || metadata.MaxFALL > 0 else {
            return nil
        }
        var payload = Data(capacity: 4)
        append(UInt16(clamping: metadata.MaxCLL), to: &payload)
        append(UInt16(clamping: metadata.MaxFALL), to: &payload)
        return payload
    }

    /// The 24-byte DOVIDecoderConfigurationRecord (dvcC/dvvC payload),
    /// bit-for-bit the layout FFmpeg's own muxers emit in
    /// ff_isom_put_dvcc_dvvc.
    private static func doviConfigurationBox(_ record: AVDOVIDecoderConfigurationRecord) -> Data {
        var payload = Data(count: 24)
        payload[0] = record.dv_version_major
        payload[1] = record.dv_version_minor
        payload[2] = ((record.dv_profile & 0x7F) << 1) | ((record.dv_level & 0x3F) >> 5)
        payload[3] = ((record.dv_level & 0x1F) << 3)
            | (min(record.rpu_present_flag, 1) << 2)
            | (min(record.el_present_flag, 1) << 1)
            | min(record.bl_present_flag, 1)
        payload[4] = ((record.dv_bl_signal_compatibility_id & 0x0F) << 4)
            | ((record.dv_md_compression & 0x03) << 2)
        return payload
    }

    private static func rescale(_ value: AVRational, by steps: Int64) -> Int64 {
        let denominator = Int64(max(value.den, 1))
        return (Int64(value.num) * steps + denominator / 2) / denominator
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
