import Dispatch
import Foundation

/// How many threads libavcodec is given for software video decode (HEL-137
/// lever 2).
///
/// `thread_count = 0` means auto, and auto counts every core the SoC reports.
/// On an A15 that is six: two performance cores and four efficiency cores. A
/// frame-threaded decoder spread across efficiency cores can spend more in
/// synchronisation than the extra cores return, so the alternative worth
/// measuring is a count bounded to the performance cluster.
///
/// **Auto remains the default and nothing here changes without the toggle.**
/// Which of the two is faster is a question about a specific device, and the
/// only honest answer is a measured one: same scene, same media-time window,
/// three or more runs. Settings → Advanced → Limit Software Decode Threads
/// exists so that A/B can be run on an Apple TV, which cannot be paired to
/// Xcode and so cannot be profiled any other way.
nonisolated enum SoftwareDecodeThreadPolicy {
    static let boundToPerformanceCoresDefaultsKey = "debug.softwareDecodePerformanceCores"
    /// HEL-137 lever 6. dav1d overlaps this many frames at once; more of them
    /// is more frame-level parallelism, paid for in latency and in decoded
    /// frames held inside the decoder. libavcodec leaves it on dav1d's own
    /// automatic choice, which is derived from the thread count and is
    /// conservative. Off, nothing is set and dav1d decides.
    static let frameDelayDefaultsKey = "debug.softwareDecodeFrameDelay"
    /// Whether the decode queue asks for the scheduling band the renderer
    /// pump already uses. dav1d's worker threads inherit the queue's class,
    /// and `userInitiated` leaves the scheduler free to place them on an
    /// A15's four efficiency cores.
    static let highPriorityDefaultsKey = "debug.softwareDecodeHighPriority"
    /// Whether dav1d is told to hand film grain parameters over instead of
    /// synthesizing the grain itself.
    ///
    /// AV1 film grain is a per-pixel post-process across the whole frame, and
    /// at 4K 10-bit it is a large share of what decoding a frame costs. It is
    /// also how a 13 Mbps 4K HDR10+ encode is possible at all: the encoder
    /// strips the grain, which is expensive to code, and the decoder puts it
    /// back. Skipping it is therefore a picture change, not a free win, which
    /// is why it is a toggle and why the default synthesizes it as the
    /// bitstream asks.
    static let skipFilmGrainDefaultsKey = "debug.softwareDecodeSkipFilmGrain"

    static func skipsFilmGrain(
        enabled: Bool = UserDefaults.standard.bool(forKey: skipFilmGrainDefaultsKey)
    ) -> Bool {
        enabled
    }

    /// Frames dav1d may have in flight, or zero to leave the decision to it.
    /// Bounded well below dav1d's own ceiling: each frame in flight is another
    /// 4K surface held inside the decoder, on top of the queue this engine
    /// already accounts for.
    static func maxFrameDelay(
        enabled: Bool = UserDefaults.standard.bool(forKey: frameDelayDefaultsKey),
        activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int32 {
        guard enabled, activeProcessors > 0 else { return 0 }
        return Int32(min(max(activeProcessors, 2), 8))
    }

    static func decodeQueueQoS(
        highPriority: Bool = UserDefaults.standard.bool(forKey: highPriorityDefaultsKey)
    ) -> DispatchQoS {
        highPriority ? .userInteractive : .userInitiated
    }

    /// What to write into `AVCodecContext.thread_count`. Zero is libavcodec's
    /// "decide for yourself".
    ///
    /// The bounded count never drops below two: one thread is the
    /// configuration HEL-103 measured at 13.26 s of decode for 30 s of 4K
    /// AV1, and a device that reports a single performance core is not a
    /// reason to go back to it.
    static func threadCount(
        performanceCores: Int,
        activeProcessors: Int,
        boundToPerformanceCores: Bool
    ) -> Int32 {
        guard boundToPerformanceCores else { return 0 }
        guard performanceCores > 0, activeProcessors > 0 else { return 0 }
        return Int32(min(max(performanceCores, 2), activeProcessors))
    }

    /// The current device's answer to the above.
    static func resolvedThreadCount(
        boundToPerformanceCores: Bool = UserDefaults.standard.bool(
            forKey: boundToPerformanceCoresDefaultsKey
        )
    ) -> Int32 {
        threadCount(
            performanceCores: performanceCoreCount(),
            activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
            boundToPerformanceCores: boundToPerformanceCores
        )
    }

    /// Cores in the fastest cluster. Apple silicon numbers its clusters from
    /// the fastest down (`hw.perflevel0` is the performance cluster on every
    /// asymmetric SoC, and the only level on a symmetric one), so this is the
    /// performance-core count without hard-coding a chip. Zero when the
    /// sysctl is missing, which the caller reads as "cannot tell".
    static func performanceCoreCount() -> Int {
        var count = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0 else {
            return 0
        }
        return max(count, 0)
    }
}
