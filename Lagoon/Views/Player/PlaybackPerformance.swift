import Foundation
import OSLog

/// Instruments/Console category shared by the controller and engine.
/// Signposts stay enabled in Release so the TestFlight-only hardware path
/// can be measured without shipping a separate diagnostics build (HEL-56).
enum PlaybackPerformance {
    nonisolated static let log = OSLog(
        subsystem: "ee.helop.lagoon",
        category: "PlaybackPerformance"
    )
}

nonisolated struct VideoPerformanceSnapshot {
    let totalFrames: Int
    let droppedFrames: Int
    let corruptedFrames: Int
}
