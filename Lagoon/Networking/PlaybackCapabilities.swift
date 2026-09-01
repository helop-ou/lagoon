import CoreMedia
import Foundation
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
    /// Whether AV1 should be handed to VideoToolbox even where there is no
    /// hardware decoder for it (HEL-137).
    ///
    /// The routing above asks `VTIsHardwareDecodeSupported`, which as this
    /// file's own comment says reports hardware and nothing else. Apple has
    /// shipped a *software* AV1 decoder inside VideoToolbox since iOS 17 for
    /// devices without the silicon, so a false there has never meant
    /// "VideoToolbox cannot decode this" — only "not in hardware". Lagoon went
    /// straight to libdav1d on that answer, which on an Apple TV costs about
    /// 30 ms of a 41.7 ms frame budget for 4K 10-bit and cannot hold frame
    /// rate once the box warms up.
    ///
    /// Off by default until measured on hardware: if the platform has no AV1
    /// decoder of any kind, asking for one fails the title rather than falling
    /// back, and that failure is itself the answer.
    let systemAV1: Bool

    static let systemAV1DefaultsKey = "debug.videoToolboxAV1"

    init(hardwareHEVC: Bool, hardwareAV1: Bool = false, systemAV1: Bool = false) {
        self.hardwareHEVC = hardwareHEVC
        self.hardwareAV1 = hardwareAV1
        self.systemAV1 = systemAV1
    }

    /// Whether AV1 leaves the demuxer compressed, for an Apple decoder,
    /// rather than being decoded by libavcodec.
    var decodesAV1WithVideoToolbox: Bool { hardwareAV1 || systemAV1 }

    /// Resolved once per process. Hardware does not grow a decoder mid-session,
    /// and the profile is rebuilt on every `PlaybackInfo` call.
    static let current = PlaybackCapabilities(
        hardwareHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        hardwareAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
        systemAV1: UserDefaults.standard.bool(forKey: systemAV1DefaultsKey)
    )
}
