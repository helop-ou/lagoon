import Foundation
import Testing
@testable import Lagoon

/// The DoVi P7 enhancement-layer strip (HEL-64) mangles the video
/// bitstream on purpose — these tests are what keeps "on purpose" honest:
/// only unspec-62/63 NALs leave, every kept byte survives verbatim, and
/// anything that doesn't parse passes through untouched.
struct HEVCEnhancementLayerFilterTests {
    /// One length-prefixed NAL unit: 4-byte (or shorter) big-endian length,
    /// then the two HEVC header bytes, then filler.
    private func nal(type: UInt8, payloadBytes: Int, lengthSize: Int = 4, filler: UInt8 = 0xAB) -> Data {
        var data = Data()
        let length = payloadBytes + 2
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((length >> shift) & 0xFF))
        }
        data.append(type << 1)
        data.append(0x01) // nuh_temporal_id_plus1
        data.append(contentsOf: repeatElement(filler, count: payloadBytes))
        return data
    }

    private func strip(_ payload: Data, lengthSize: Int = 4) -> Data? {
        payload.withUnsafeBytes { bytes in
            HEVCEnhancementLayerFilter.strippingEnhancementLayer(from: bytes, lengthSize: lengthSize)
        }
    }

    /// The realistic access unit: parameter sets, SEI, a VCL slice, and
    /// the DoVi RPU (62) + EL (63) interleaved the way P7 remuxes do.
    @Test func stripsOnlyEnhancementLayerAndRPU() {
        let kept = nal(type: 32, payloadBytes: 4) + nal(type: 33, payloadBytes: 6)
            + nal(type: 39, payloadBytes: 10) + nal(type: 1, payloadBytes: 500, filler: 0xCD)
        let payload = nal(type: 32, payloadBytes: 4) + nal(type: 33, payloadBytes: 6)
            + nal(type: 62, payloadBytes: 20)
            + nal(type: 39, payloadBytes: 10) + nal(type: 1, payloadBytes: 500, filler: 0xCD)
            + nal(type: 63, payloadBytes: 3000, filler: 0xEF)
        #expect(strip(payload) == kept)
    }

    @Test func nothingToStripReturnsNilSoZeroCopyStays() {
        let payload = nal(type: 32, payloadBytes: 4) + nal(type: 1, payloadBytes: 100)
        #expect(strip(payload) == nil)
    }

    @Test func entirePayloadStrippableLeavesEmptyData() {
        // Degenerate but well-formed: an AU of nothing but EL. The empty
        // result is the caller's cue to keep behavior sane (the factory
        // rejects zero-size payloads rather than enqueue an empty sample).
        let payload = nal(type: 63, payloadBytes: 10)
        #expect(strip(payload) == Data())
    }

    @Test func truncatedLengthPrefixPassesThroughUntouched() {
        var payload = nal(type: 62, payloadBytes: 10)
        payload.append(contentsOf: [0x00, 0x00]) // half a length prefix
        #expect(strip(payload) == nil)
    }

    @Test func lengthOverrunPassesThroughUntouched() {
        var payload = Data([0x00, 0x00, 0x10, 0x00]) // claims 4096 bytes
        payload.append(62 << 1)
        payload.append(0x01)
        #expect(strip(payload) == nil)
    }

    @Test func zeroLengthNALPassesThroughUntouched() {
        var payload = nal(type: 62, payloadBytes: 5)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // zero-length unit
        #expect(strip(payload) == nil)
    }

    @Test func honorsSmallerLengthPrefixes() {
        let payload = nal(type: 1, payloadBytes: 40, lengthSize: 2)
            + nal(type: 63, payloadBytes: 60, lengthSize: 2)
        let kept = nal(type: 1, payloadBytes: 40, lengthSize: 2)
        #expect(strip(payload, lengthSize: 2) == kept)
    }

    /// hvcC's lengthSizeMinusOne lives in the low bits of byte 21.
    @Test func nalLengthSizeReadFromHvcC() {
        var hvcc = Data(count: 23)
        hvcc[21] = 0xFF // …| lengthSizeMinusOne = 3
        #expect(HEVCEnhancementLayerFilter.nalLengthSize(hvcc: hvcc) == 4)
        hvcc[21] = 0xFC | 0x01
        #expect(HEVCEnhancementLayerFilter.nalLengthSize(hvcc: hvcc) == 2)
        #expect(HEVCEnhancementLayerFilter.nalLengthSize(hvcc: Data(count: 10)) == nil)
    }
}
