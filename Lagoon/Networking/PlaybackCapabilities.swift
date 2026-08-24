import CoreMedia
import VideoToolbox

/// What the running device can actually decode, as distinct from what the
/// engine knows how to ask for.
///
/// `VTIsHardwareDecodeSupported` reports *hardware* support and nothing else —
/// on the tvOS simulator it
/// answers false for every codec including H.264, which the simulator plainly
/// plays. Gating on it wholesale would strip a profile down to nothing.
///
/// So the rule is: query exactly the paths where the answer changes routing.
/// HEVC requires hardware. `VideoToolboxDecoder` creates its session with
/// `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`, so a
/// device without one cannot play HEVC at all — it answers -12906 and the
/// title fails. AV1 uses that same compressed hardware path where available,
/// but has Lagoon's bounded libdav1d software path otherwise. H.264 is handed
/// to `AVSampleBufferVideoRenderer` compressed and may be decoded in software;
/// the remaining advertised codecs are decoded by libavcodec on the CPU.
///
/// Apple notes that a true here "does not guarantee that hardware decode
/// resources will be available at all times", so this narrows what Lagoon
/// claims without ever promising it — the delivery ladder (HEL-100) is what
/// covers the remainder.
nonisolated struct PlaybackCapabilities: Equatable, Sendable {
    let hardwareHEVC: Bool
    let hardwareAV1: Bool

    init(hardwareHEVC: Bool, hardwareAV1: Bool = false) {
        self.hardwareHEVC = hardwareHEVC
        self.hardwareAV1 = hardwareAV1
    }

    /// Resolved once per process. Hardware does not grow a decoder mid-session,
    /// and the profile is rebuilt on every `PlaybackInfo` call.
    static let current = PlaybackCapabilities(
        hardwareHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        hardwareAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    )
}
