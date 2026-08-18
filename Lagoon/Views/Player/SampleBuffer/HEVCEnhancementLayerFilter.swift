import Foundation

/// Strips the Dolby Vision enhancement layer out of a single-track
/// profile 7 HEVC stream (HEL-64 hardware experiment, Settings → Debug).
///
/// P7 remuxes interleave the enhancement layer and RPU into the base
/// layer's track as NAL units of the unspecified types 63 and 62. The
/// decoder can't use either — tvOS cannot reconstruct dual-layer DoVi and
/// the engine plays P7 as HDR10 off the base layer — but it still has to
/// parse past them on every frame: on Snowden that is 14.5% of an 86 Mbps
/// bitstream (~11 Mbps, ~4 units per frame) of skip-work. Whether that
/// parsing is what drops frames on real hardware is exactly what the
/// toggle exists to A/B; the simulator decodes in software and cannot
/// answer it.
nonisolated enum HEVCEnhancementLayerFilter {
    /// NAL length-prefix size from the hvcC box (lengthSizeMinusOne, byte
    /// 21) — mp4-style payloads prefix every NAL with this many bytes.
    static func nalLengthSize(hvcc: Data) -> Int? {
        guard hvcc.count > 22 else { return nil }
        return Int(hvcc[hvcc.startIndex + 21] & 0x3) + 1
    }

    /// The payload with unspec-62/63 NALs removed. Returns nil when there
    /// is nothing to strip — so the zero-copy packet path stays in use —
    /// and nil when the payload doesn't parse as length-prefixed NALs, so
    /// a malformed packet passes through untouched rather than mangled.
    static func strippingEnhancementLayer(
        from payload: UnsafeRawBufferPointer,
        lengthSize: Int
    ) -> Data? {
        guard let base = payload.baseAddress, (1...4).contains(lengthSize) else { return nil }
        let count = payload.count
        // Kept byte ranges, coalesced so consecutive surviving NALs copy
        // in one memmove.
        var kept: [(start: Int, end: Int)] = []
        var strippedBytes = 0
        var offset = 0
        while offset < count {
            guard offset + lengthSize <= count else { return nil }
            var nalLength = 0
            for index in 0..<lengthSize {
                nalLength = nalLength << 8 | Int(payload[offset + index])
            }
            let unitEnd = offset + lengthSize + nalLength
            guard nalLength > 0, unitEnd <= count else { return nil }
            let nalType = (payload[offset + lengthSize] >> 1) & 0x3F
            if nalType == 62 || nalType == 63 {
                strippedBytes += unitEnd - offset
            } else if !kept.isEmpty, kept[kept.count - 1].end == offset {
                kept[kept.count - 1].end = unitEnd
            } else {
                kept.append((offset, unitEnd))
            }
            offset = unitEnd
        }
        guard strippedBytes > 0 else { return nil }
        var result = Data(capacity: count - strippedBytes)
        for range in kept {
            result.append(
                base.advanced(by: range.start).assumingMemoryBound(to: UInt8.self),
                count: range.end - range.start
            )
        }
        return result
    }
}
