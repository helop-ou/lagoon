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
