import Dispatch
import Foundation

/// How libavcodec is configured for software video decode (HEL-137).
///
/// What is left here is what survived being measured on an Apple TV. The
/// settings that did not are gone rather than left switched off: the thread
/// count (5 by default on that device, 6 identical, 8 about 10% better cold
/// and hotter for it), dav1d's `max_frame_delay` (worse), and the decode
/// queue's scheduling band (never the constraint once heat was). Film grain
/// went too, once the HUD reported that the stream carries none.
nonisolated enum SoftwareDecodeThreadPolicy {
    /// Whether software-decoded video is presented without its HDR
    /// signalling, so tvOS keeps the display in SDR.
    ///
    /// Firecore's answer about Infuse: "True HDR output is not available for
    /// AV1 videos on the Apple TV, so Infuse will (correctly) set the output
    /// to SDR when playing these. Other apps may be switching your TV to HDR
    /// (or Dolby Vision) mode, but this is not technically correct." Lagoon is
    /// one of those other apps: it attaches PQ and HDR10 metadata to
    /// libdav1d's frames and asks for a matching display mode.
    ///
    /// Two things follow, and this toggle is for the second. The first is
    /// correctness, which is its own question. The second is that compositing
    /// 4K PQ into an HDR output is GPU and memory-bandwidth work on the same
    /// chip trying to run dav1d, and heat is exactly what has been eating this
    /// ticket's margin.
    ///
    /// **A measurement, not a mode.** Nothing tone maps, so PQ content
    /// signalled as BT.709 looks dark and flat. If HDR output turns out to be
    /// what costs the headroom, the work is to tone map properly.
    static let forceSDRDefaultsKey = "debug.softwareDecodeForceSDR"

    static func forcesSDROutput(
        enabled: Bool = UserDefaults.standard.bool(forKey: forceSDRDefaultsKey)
    ) -> Bool {
        enabled
    }

    /// Threads for libavcodec, and never its "auto".
    ///
    /// Auto left the resolved value inside the dav1d wrapper, where nothing on
    /// a device that cannot be paired to Xcode could read it, and
    /// `thread_count` is not written back by `avcodec_open2` — so a build
    /// shipped with nobody able to say how many threads were decoding. Every
    /// core the device reports is what auto was believed to be choosing,
    /// stated explicitly so it is at least legible on the HUD.
    ///
    /// Sweeping it on hardware moved 4K AV1 by about 10% at best, so there is
    /// no setting for it: dav1d's parallelism here is limited by the stream,
    /// not by the count.
    static func resolvedThreadCount(
        explicit: Int = UserDefaults.standard.integer(forKey: threadCountDefaultsKey),
        activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int32 {
        if explicit > 0 {
            return Int32(min(explicit, max(activeProcessors * 4, 2)))
        }
        return Int32(max(activeProcessors, 1))
    }

    /// Diagnostic knobs with no Settings UI, read from launch arguments:
    /// `-debug.softwareDecodeThreadCount 8`, `-debug.softwareDecodeFrameDelay 6`.
    ///
    /// They live here rather than on the Advanced page because they are for
    /// sweeping from a Mac against a paired Apple TV, not for anyone to set.
    /// Both were "measured" once from the HUD and both answers were worthless:
    /// decode cost on this content tracks scene complexity, so a cumulative
    /// average read at a different playback position compares scenes rather
    /// than settings (HEL-137).
    static let threadCountDefaultsKey = "debug.softwareDecodeThreadCount"
    static let frameDelayDefaultsKey = "debug.softwareDecodeFrameDelay"

    /// Frames dav1d may have in flight, or zero to leave it to dav1d.
    static func maxFrameDelay(
        explicit: Int = UserDefaults.standard.integer(forKey: frameDelayDefaultsKey)
    ) -> Int32 {
        Int32(max(min(explicit, 16), 0))
    }
}
