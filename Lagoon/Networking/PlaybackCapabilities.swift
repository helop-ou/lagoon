import CoreMedia
import VideoToolbox

/// What the running device can actually decode, as distinct from what the
/// engine knows how to ask for.
///
/// Only one thing is asked, and deliberately so. `VTIsHardwareDecodeSupported`
/// reports *hardware* support and nothing else — on the tvOS simulator it
/// answers false for every codec including H.264, which the simulator plainly
/// plays. Gating on it wholesale would strip a profile down to nothing.
///
/// So the rule is: gate exactly what the engine requires hardware for, which
/// is HEVC alone. `VideoToolboxDecoder` creates its session with
/// `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`, so a
/// device without one cannot play HEVC at all — it answers -12906 and the
/// title fails. H.264 is handed to `AVSampleBufferVideoRenderer` compressed
/// and may be decoded in software; VC-1 and MPEG-4 Part 2 are decoded by
/// libavcodec on the CPU. None of those depend on this answer.
///
/// Apple notes that a true here "does not guarantee that hardware decode
/// resources will be available at all times", so this narrows what Lagoon
/// claims without ever promising it — the delivery ladder (HEL-100) is what
/// covers the remainder.
nonisolated struct PlaybackCapabilities: Equatable, Sendable {
    let hardwareHEVC: Bool

    init(hardwareHEVC: Bool) {
        self.hardwareHEVC = hardwareHEVC
    }

    /// Resolved once per process. Hardware does not grow a decoder mid-session,
    /// and the profile is rebuilt on every `PlaybackInfo` call.
    static let current = PlaybackCapabilities(
        hardwareHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    )
}
