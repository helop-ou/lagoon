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

    // MARK: - Parameter sets the container may or may not carry (HEL-131)

    /// A well-formed record: 22 bytes of header, numOfArrays, then one
    /// array per parameter-set type.
    private func hvcC(arrays: [(type: UInt8, length: Int)]) -> Data {
        var data = Data(count: 22)
        data[21] = 0xFF // lengthSizeMinusOne = 3
        data.append(UInt8(arrays.count))
        for array in arrays {
            data.append(array.type)             // array_completeness | nal type
            data.append(contentsOf: [0x00, 0x01]) // numNalus = 1
            data.append(UInt8((array.length >> 8) & 0xFF))
            data.append(UInt8(array.length & 0xFF))
            data.append(contentsOf: repeatElement(0xAB, count: array.length))
        }
        return data
    }

    /// The exact 23-byte record from the file that found this: an hvcC whose
    /// header is entirely valid and which declares no parameter sets at all.
    /// The decoder cannot be configured from it, and nothing says so until
    /// VTDecompressionSessionCreate refuses.
    @Test func anEmptyParameterSetListIsRecognised() {
        let empty = Data([
            0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x96, 0xf0, 0x00, 0xfc,
            0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x00,
        ])
        #expect(empty.count == 23)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(empty) == false)
        // The length prefix is still described correctly, which is what the
        // harvest relies on to walk the packets.
        #expect(HEVCEnhancementLayerFilter.nalLengthSize(hvcc: empty) == 4)
    }

    @Test func aRecordCarryingSPSAndPPSIsAccepted() {
        let full = hvcC(arrays: [(32, 24), (33, 58), (34, 7)])
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(full))
    }

    /// Both have to be there. A VPS on its own configures nothing.
    @Test func aRecordMissingEitherHalfIsRejected() {
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(hvcC(arrays: [(32, 24)])) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(
            hvcC(arrays: [(32, 24), (33, 58)])
        ) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(
            hvcC(arrays: [(33, 58), (34, 7)])
        ))
    }

    /// A record that lies about its own lengths is treated as carrying
    /// nothing rather than read past its end.
    @Test func aTruncatedRecordIsRejectedRatherThanOverread() {
        var truncated = hvcC(arrays: [(32, 24), (33, 58), (34, 7)])
        truncated = truncated.prefix(30)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(truncated) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(Data(count: 10)) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(Data()) == false)
    }
}
