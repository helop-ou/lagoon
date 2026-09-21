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
/// claims without ever promising it — the delivery ladder is what
/// covers the remainder.
nonisolated struct PlaybackCapabilities: Equatable, Sendable {
    let hardwareHEVC: Bool
    let hardwareAV1: Bool
    /// Whether AV1 may be offered to VideoToolbox at all.
    ///
    /// `VTIsHardwareDecodeSupported` reports hardware and nothing else, as
    /// this file's own comment has always said, and Apple ships a *software*
    /// AV1 decoder inside VideoToolbox on some platforms — so a false there
    /// has never meant "VideoToolbox cannot decode this". Lagoon went straight
    /// to libdav1d on that answer and never asked the real question.
    ///
    /// So AV1 is always offered, and `VideoToolboxDecoder.canDecode` settles
    /// it per stream by trying to create a session. On an A15 that answers no
    /// (-12906, measured) and the engine reopens on the software path; where a
    /// decoder does exist, hardware or software, it is used without anyone
    /// having to have predicted which.
    var decodesAV1WithVideoToolbox: Bool { true }

    init(hardwareHEVC: Bool, hardwareAV1: Bool = false) {
        self.hardwareHEVC = hardwareHEVC
        self.hardwareAV1 = hardwareAV1
    }

    /// What the hardware answers, resolved once per process: it does not grow
    /// a decoder mid-session.
    private static let hardware = (
        hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    )

    static var current: PlaybackCapabilities {
        PlaybackCapabilities(hardwareHEVC: hardware.hevc, hardwareAV1: hardware.av1)
    }
}
