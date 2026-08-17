import Foundation
import OSLog
import os

/// Instruments/Console category shared by the controller and engine.
/// Signposts stay enabled in Release so the TestFlight-only hardware path
/// can be measured without shipping a separate diagnostics build (HEL-56).
enum PlaybackPerformance {
    nonisolated static let log = OSLog(
        subsystem: "ee.helop.lagoon",
        category: "PlaybackPerformance"
    )
}

/// App memory at a point in time. Playback is the only place where a slow
/// leak is invisible until it is fatal: jetsam kills for `per-process-limit`
/// leave a JetsamEvent report, not a crash trace, so nothing in the signpost
/// stream explains the disappearance. Sampling it alongside the other
/// playback metrics makes the climb obvious while it is still harmless.
nonisolated struct MemorySnapshot {
    /// What jetsam weighs against the per-process limit.
    let footprintBytes: Int64
    /// Headroom left before that limit; 0 when the platform won't report it.
    let availableBytes: Int

    var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    var availableMB: Double { Double(availableBytes) / 1_048_576 }

    static func current() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return MemorySnapshot(
            footprintBytes: status == KERN_SUCCESS ? Int64(info.phys_footprint) : 0,
            availableBytes: os_proc_available_memory()
        )
    }
}

nonisolated struct VideoPerformanceSnapshot {
    let totalFrames: Int
    let droppedFrames: Int
    let corruptedFrames: Int
}
