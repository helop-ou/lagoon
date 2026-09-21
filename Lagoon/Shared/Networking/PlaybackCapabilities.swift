import CoreMedia
import Foundation
import VideoToolbox

/// What the device can decode, as opposed to what the engine can ask for.
///
/// `VTIsHardwareDecodeSupported` reports hardware only, and answers false for
/// every codec on the simulator — including H.264, which it plainly plays. So
/// query only the paths where the answer changes routing:
///
/// - HEVC needs hardware. The session is created requiring it, so a device
///   without one answers -12906 and the title fails.
/// - AV1 uses hardware where available, bounded libdav1d otherwise.
/// - H.264 goes to the renderer compressed; the rest are libavcodec on CPU.
///
/// A true is not a promise of availability. The delivery ladder covers that.
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
