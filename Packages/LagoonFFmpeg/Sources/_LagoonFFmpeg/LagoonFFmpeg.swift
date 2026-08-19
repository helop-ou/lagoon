import LagoonPixelOps

/// SIMD pixel primitives kept beside the pinned FFmpeg binaries. VC-1 emits
/// planar 4:2:0, while Core Video's Apple-recommended output is NV12; doing
/// the chroma zip in Swift consumed the software decoder's entire real-time
/// budget on Apple TV.
public enum LagoonPixelConversion {
    public static func interleave420Chroma(
        sourceU: UnsafePointer<UInt8>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt8>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_interleave_420_chroma(
            sourceU,
            sourceUStride,
            sourceV,
            sourceVStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }
}
